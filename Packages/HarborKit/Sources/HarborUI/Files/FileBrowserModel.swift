import AppKit
import HarborCore
import HarborFiles
import HarborLogging
import HarborSessions
import HarborSSH
import Observation

/// State and actions for one tab's file flyout. Local tabs browse this Mac; SSH tabs
/// browse the host over SFTP, riding the tab's authenticated connection.
@MainActor
@Observable
final class FileBrowserModel {
    let session: TerminalSession
    let browser: any FileBrowsing
    private(set) var path = ""
    private(set) var entries: [FileEntry] = []
    private(set) var isLoading = false
    private(set) var error: String?
    var showHidden = false
    /// Follow the terminal's working directory as it changes.
    var followsTerminal = true
    /// Instant filter for the current directory's items (`/` in the file list).
    var filterQuery = ""
    var isFiltering = false
    /// Toggle between clickable breadcrumbs and an editable path field (`⇧⌘G`).
    var isEditingPath = false

    /// Hands the keyboard back to the terminal, replaying `event` there if given. Set by
    /// the tab's container.
    @ObservationIgnored var returnFocusToTerminal: @MainActor (NSEvent?) -> Void = { _ in }

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let log = Log(.sftp)
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var editWatchers: [URL: FileWatcher] = [:]

    init(session: TerminalSession, services: AppServices) {
        self.session = session
        self.services = services
        if let host = session.kind.host {
            let builder = SSHCommandBuilder(settings: services.settings.settings.ssh, controlDirectory: services.paths.sshControl)
            browser = RemoteFileBrowser.ssh(host: host, builder: builder)
        } else {
            browser = LocalFileBrowser()
        }
    }

    var transfers: TransferCenter { services.transfers }
    var clipboard: FileClipboard { services.clipboard }
    var isRemote: Bool { browser.isRemote }
    var title: String { browser.isRemote ? browser.title : "This Mac" }

    var visibleEntries: [FileEntry] {
        let trimmed = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            guard showHidden || !entry.isHidden else { return false }
            guard !trimmed.isEmpty else { return true }
            return entry.name.localizedCaseInsensitiveContains(trimmed)
                || FuzzyMatcher.score(trimmed, in: entry.name) != nil
        }.sorted(by: FileEntry.finderOrder)
    }

    // MARK: Lifecycle

    func activate() async {
        isActive = true
        if path.isEmpty {
            let start = session.workingDirectory ?? session.kind.host?.remoteDirectory
            if let start {
                await load(start)
            } else {
                do {
                    await load(try await browser.homeDirectory())
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        observeTerminalDirectory()
    }

    func deactivate() async {
        isActive = false
        editWatchers.values.forEach { $0.stop() }
        editWatchers.removeAll()
        if let remote = browser as? RemoteFileBrowser { await remote.disconnect() }
    }

    private func observeTerminalDirectory() {
        withObservationTracking {
            _ = session.workingDirectory
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                if self.followsTerminal, let directory = self.session.workingDirectory, directory != self.path {
                    await self.load(directory)
                }
                self.observeTerminalDirectory()
            }
        }
    }

    // MARK: Navigation

    func load(_ newPath: String) async {
        let expanded = isRemote ? newPath : (newPath as NSString).expandingTildeInPath
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await browser.list(expanded)
            path = expanded
            filterQuery = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
            log.warning("listing \(expanded) failed: \(error.localizedDescription)")
        }
    }

    func refresh() async {
        guard !path.isEmpty else { return await activate() }
        await load(path)
    }

    func goUp() async {
        await load(RemotePath.parent(of: path))
    }

    func open(_ entry: FileEntry) async {
        do {
            let resolved = try await browser.resolve(entry)
            if resolved.isDirectory {
                await load(resolved.path)
            } else if isRemote {
                download([resolved], to: downloadsDirectory, reveal: true)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: resolved.path))
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Prepares a local file URL for Quick Look (`Space`), downloading remote files ≤ 10 MB to a temporary folder.
    func previewFileURL(for entry: FileEntry) async throws -> URL {
        let resolved = try await browser.resolve(entry)
        guard !resolved.isDirectory else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        if !isRemote {
            return URL(fileURLWithPath: resolved.path)
        }
        if let size = resolved.size, size > 10 * 1024 * 1024 {
            throw CocoaError(.fileReadTooLarge, userInfo: [NSLocalizedDescriptionKey: "Quick Look over SFTP is limited to files under 10 MB."])
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborQuickLook-\(session.id.shortDescription)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try await browser.download(resolved, into: dir, progress: { _, _ in })
    }

    /// Downloads a remote file to a temporary directory, opens it in the default macOS editor,
    /// and watches for saves to automatically re-upload over SFTP.
    func openInDefaultEditor(_ entry: FileEntry) async {
        do {
            let resolved = try await browser.resolve(entry)
            guard !resolved.isDirectory else { return }
            if !isRemote {
                NSWorkspace.shared.open(URL(fileURLWithPath: resolved.path))
                return
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("HarborEdit-\(session.id.shortDescription)-\(UUID().uuidString.prefix(6))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let remoteParent = RemotePath.parent(of: resolved.path)
            let browser = browser
            let transfer = transfers.enqueue(name: resolved.name, direction: .download) { progress in
                try await browser.download(resolved, into: dir, progress: progress)
            }
            while transfer.isActive {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let localURL = transfer.resultURL else { return }
            NSWorkspace.shared.open(localURL)

            editWatchers[localURL]?.stop()
            let watcher = FileWatcher(url: localURL) { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.upload([localURL], into: remoteParent)
                }
            }
            editWatchers[localURL] = watcher
            watcher.start()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Transfers

    var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? services.paths.home
    }

    func download(_ entries: [FileEntry], to directory: URL, reveal: Bool = false) {
        for entry in entries {
            let browser = browser
            transfers.enqueue(name: entry.name, direction: .download) { progress in
                let url = try await browser.download(entry, into: directory, progress: progress)
                if reveal { await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                return url
            }
        }
    }

    /// Fulfils a Finder file promise: copies `entry` to the exact URL Finder chose.
    func fulfilPromise(for entry: FileEntry, at url: URL) async throws {
        let browser = browser
        let transfer = transfers.enqueue(name: entry.name, direction: .download) { progress in
            try await browser.copy(entry, to: url, progress: progress)
            return url
        }
        while transfer.isActive { try await Task.sleep(for: .milliseconds(100)) }
        if case .failed(let message) = transfer.state {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func upload(_ urls: [URL], into directory: String? = nil) async {
        if path.isEmpty { await activate() }
        let target = directory ?? path
        guard !target.isEmpty else { return }
        for url in urls {
            let browser = browser
            let transfer = transfers.enqueue(name: url.lastPathComponent, direction: .upload) { progress in
                try await browser.upload(url, into: target, progress: progress)
                return nil
            }
            Task { [weak self] in
                while transfer.isActive { try? await Task.sleep(for: .milliseconds(200)) }
                if target == self?.path { await self?.refresh() }
            }
        }
    }

    // MARK: Clipboard

    func copyToClipboard(_ entries: [FileEntry]) {
        services.clipboard.copy(entries, from: browser)
    }

    /// Pastes what's on the clipboard into `directory` (the folder shown when nil), uploading
    /// to this tab's host.
    func paste(into directory: String? = nil) async {
        let urls = await services.clipboard.itemsToPaste()
        guard !urls.isEmpty else { return }
        await upload(urls, into: directory)
    }

    // MARK: File operations

    func makeFolder(named name: String) async {
        await perform { try await self.browser.makeDirectory(RemotePath.join(self.path, name)) }
    }

    func rename(_ entry: FileEntry, to name: String) async {
        guard !name.isEmpty, name != entry.name, !name.contains("/") else { return }
        await perform { try await self.browser.rename(entry.path, to: RemotePath.join(RemotePath.parent(of: entry.path), name)) }
    }

    func delete(_ entries: [FileEntry]) async {
        await perform {
            for entry in entries { try await self.browser.delete(entry) }
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    // MARK: Terminal integration

    var canChangeTerminalDirectory: Bool {
        session.state.isRunning && (session.isAtPrompt || session.shellIntegration == nil)
    }

    func changeTerminalDirectory(to directory: String) {
        session.send(text: "cd \(ShellQuoting.quote(directory))\r")
        returnFocusToTerminal(nil)
    }

    func copyPath(_ entry: FileEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.path, forType: .string)
    }
}
