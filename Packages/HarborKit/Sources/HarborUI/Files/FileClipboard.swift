import AppKit
import HarborFiles
import HarborLogging
import Observation

/// Copy and paste for files and folders, across tabs and hosts.
///
/// Copying from a remote host downloads the items to a holding folder on this Mac, then
/// puts them on the system pasteboard as files. Any tab's file list can paste them
/// (uploading to its host), and so can Finder. They stay pasteable after the source tab
/// closes or Harbor restarts. Files copied in Finder paste into Harbor the same way.
@MainActor
@Observable
final class FileClipboard {
    /// What's waiting to be pasted, for the flyout's clipboard row.
    struct Contents: Equatable {
        var names: [String]
        var source: String
        /// Still downloading from the source host. Pasting waits for it.
        var isStaging: Bool

        var summary: String {
            let what = names.count == 1 ? "“\(names[0])”" : "\(names.count) items"
            return isStaging ? "Copying \(what) from \(source)…" : "\(what) from \(source)"
        }
    }

    private(set) var contents: Contents?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let transfers: TransferCenter
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private var staging: (folder: URL, transfers: [Transfer])?
    /// The pasteboard's change count after Harbor last wrote to it; anything else means
    /// someone copied something since.
    @ObservationIgnored private var ownChangeCount: Int?
    @ObservationIgnored private let log = Log(.sftp)

    init(directory: URL, transfers: TransferCenter, pasteboard: NSPasteboard = .general) {
        self.directory = directory
        self.transfers = transfers
        self.pasteboard = pasteboard
        pruneUnreferencedFolders()
    }

    // MARK: Copy

    func copy(_ entries: [FileEntry], from browser: any FileBrowsing) {
        guard !entries.isEmpty else { return }
        discardStaging()
        guard browser.isRemote else {
            // Local items are referenced in place, like a Finder copy.
            write(entries.map { URL(fileURLWithPath: $0.path) })
            contents = Contents(names: entries.map(\.name), source: "This Mac", isStaging: false)
            return
        }

        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            log.warning("couldn't create the clipboard folder: \(error.localizedDescription)")
            return
        }
        let started = entries.map { entry in
            transfers.enqueue(name: entry.name, direction: .download) { progress in
                try await browser.download(entry, into: folder, progress: progress)
            }
        }
        staging = (folder, started)
        // Claim the pasteboard now, so nothing older gets pasted while these download.
        pasteboard.clearContents()
        ownChangeCount = pasteboard.changeCount
        contents = Contents(names: entries.map(\.name), source: browser.title, isStaging: true)

        Task { [weak self] in
            for transfer in started { await transfer.waitUntilDone() }
            self?.stagingFinished(folder: folder, transfers: started)
        }
    }

    private func stagingFinished(folder: URL, transfers started: [Transfer]) {
        guard let current = staging, current.folder == folder, !current.transfers.isEmpty else { return } // superseded or already finished
        let urls = started.compactMap(\.resultURL)
        guard urls.count == started.count else {
            contents = nil
            discardStaging()
            return
        }
        staging = (folder, [])
        // Only take the pasteboard if nothing else was copied meanwhile.
        if pasteboard.changeCount == ownChangeCount { write(urls) }
        contents?.isStaging = false
    }

    // MARK: Paste

    /// Whether there's anything to paste (Harbor's own copy, or files from Finder).
    var canPaste: Bool {
        if contents?.isStaging == true { return true }
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// The files to paste, waiting for a copy that's still downloading.
    func itemsToPaste() async -> [URL] {
        if let current = staging, !current.transfers.isEmpty {
            for transfer in current.transfers { await transfer.waitUntilDone() }
            stagingFinished(folder: current.folder, transfers: current.transfers)
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if pasteboard.changeCount != ownChangeCount, contents?.source != nil, contents?.isStaging == false {
            // Something else was copied since (e.g. in Finder); the row no longer applies.
            contents = nil
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Housekeeping

    private func write(_ urls: [URL]) {
        pasteboard.clearContents()
        let items = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            // Text targets (a terminal, a chat box) get the name, as with a Finder copy.
            item.setString(url.lastPathComponent, forType: .string)
            return item
        }
        pasteboard.writeObjects(items)
        ownChangeCount = pasteboard.changeCount
    }

    private func discardStaging() {
        guard let staging else { return }
        staging.transfers.forEach(transfers.cancel)
        try? FileManager.default.removeItem(at: staging.folder)
        self.staging = nil
    }

    /// Removes held copies the pasteboard no longer refers to (from earlier runs).
    private func pruneUnreferencedFolders() {
        let referenced = Set((pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .map { $0.standardizedFileURL.deletingLastPathComponent().lastPathComponent })
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !referenced.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
        // A copy from the last run that's still on the pasteboard picks up where it left off.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let first = urls.first, first.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path) {
            staging = (first.deletingLastPathComponent(), [])
            ownChangeCount = pasteboard.changeCount
            contents = Contents(names: urls.map(\.lastPathComponent), source: "an earlier session", isStaging: false)
        }
    }
}
