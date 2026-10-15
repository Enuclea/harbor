import AppKit
import HarborCore
import HarborSessions
import SwiftUI
import UniformTypeIdentifiers

/// A terminal window holding any number of sessions as tabs in its title-bar strip.
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model = WindowTabsModel()
    private var containers: [SessionID: TerminalContainerView] = [:]
    private var root: TerminalWindowRootView!
    private let services: AppServices
    private weak var coordinator: WindowCoordinator?
    private var skipCloseConfirmation = false

    init(services: AppServices, coordinator: WindowCoordinator) {
        self.services = services
        self.coordinator = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // An empty unified toolbar gives a 52 pt title bar with centred window buttons;
        // clicks in it still reach the tab strip.
        let toolbar = NSToolbar(identifier: "HarborWindow")
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 240)
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        model.hosts = services.hosts
        root = TerminalWindowRootView(model: model, actions: makeActions())
        window.contentView = root
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Tabs

    var sessions: [TerminalSession] { model.sessions }

    var selectedSession: TerminalSession? {
        model.selectedID.flatMap { id in model.sessions.first { $0.id == id } }
    }

    var selectedContainer: TerminalContainerView? {
        model.selectedID.flatMap { containers[$0] }
    }

    func contains(_ session: TerminalSession) -> Bool {
        containers[session.id] != nil
    }

    /// Adds a session as a tab (creating its terminal view unless one is being moved in).
    func adopt(_ session: TerminalSession, container existing: TerminalContainerView? = nil, at index: Int? = nil, select: Bool = true) {
        let container = existing ?? TerminalContainerView(session: session, services: services)
        containers[session.id] = container
        let position = index.map { min(max(0, $0), model.sessions.count) } ?? model.sessions.count
        model.sessions.insert(session, at: position)
        container.binding.onBell = { [weak self, weak session] in
            guard let self, let session else { return }
            self.handleBell(in: session)
        }
        container.terminal.extraMenuItems = { [weak self] in self?.contextMenuItems() ?? [] }
        root.add(container)
        if existing == nil, model.sessions.count == 1 { sizeWindow(to: container) }
        if select || model.selectedID == nil { self.select(session) }
    }

    /// Removes a tab without ending its session (for moving it to another window).
    @discardableResult
    func release(_ session: TerminalSession) -> TerminalContainerView? {
        guard let container = containers.removeValue(forKey: session.id),
              let index = model.sessions.firstIndex(where: { $0 === session }) else { return nil }
        model.sessions.remove(at: index)
        root.remove(container)
        if model.selectedID == session.id {
            model.selectedID = nil
            let next = model.sessions.indices.contains(index) ? model.sessions[index] : model.sessions.last
            if let next { select(next) }
        }
        if model.sessions.isEmpty {
            skipCloseConfirmation = true
            window?.close()
        }
        return container
    }

    func select(_ session: TerminalSession) {
        guard let container = containers[session.id] else { return }
        model.selectedID = session.id
        root.show(container)
        session.markSeen()
        applyAppearance()
        updateWindowTitle()
        if window?.isKeyWindow == true {
            container.focusTerminal()
            container.reassertSize()
        }
        observeSelected(session)
    }

    func move(_ session: TerminalSession, before target: TerminalSession?) {
        guard let from = model.sessions.firstIndex(where: { $0 === session }) else { return }
        model.sessions.remove(at: from)
        let to = target.flatMap { target in model.sessions.firstIndex { $0 === target } } ?? model.sessions.count
        withAnimation(.snappy(duration: 0.2)) { model.sessions.insert(session, at: to) }
    }

    /// Closes one tab, asking first if it's running something.
    func closeTab(_ session: TerminalSession, confirm: Bool = true) {
        let finish = { [weak self] in
            guard let self, let container = self.release(session) else { return }
            container.teardown()
            self.coordinator?.tabWasClosed(session)
        }
        guard confirm, services.settings.settings.terminal.confirmCloseWithRunningProcess,
              session.needsCloseConfirmation, let window else {
            finish()
            return
        }
        select(session)
        let alert = NSAlert()
        alert.messageText = "Close “\(displayName(session))”?"
        alert.informativeText = "Closing it will end \(session.foregroundProcessName ?? (session.kind.host != nil ? "the SSH connection" : "what's running"))."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { finish() }
        }
    }

    // MARK: Appearance and title

    func applyAppearance() {
        containers.values.forEach { $0.applyAppearance() }
        let theme = selectedSession.map(services.theme(for:)) ?? services.currentTheme
        root.applyAppearance(theme: theme, settings: services.settings.settings)
    }

    private func updateWindowTitle() {
        guard let window, let session = selectedSession else { return }
        // The title isn't drawn (tabs are), but Mission Control and the Window menu use it.
        window.title = displayName(session)
        window.subtitle = session.lastCommandLine ?? ""
        if session.kind == .localShell, let directory = session.workingDirectory {
            window.representedURL = URL(fileURLWithPath: directory)
        } else {
            window.representedURL = nil
        }
    }

    private func observeSelected(_ session: TerminalSession) {
        withObservationTracking {
            _ = session.title
            _ = session.workingDirectory
            _ = session.lastCommandLine
        } onChange: { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session, self.model.selectedID == session.id else { return }
                self.updateWindowTitle()
                self.observeSelected(session)
            }
        }
    }

    private func sizeWindow(to container: TerminalContainerView) {
        guard let window else { return }
        let size = container.preferredContentSize
        window.setContentSize(NSSize(width: size.width, height: size.height + root.stripHeightValue))
    }

    private func handleBell(in session: TerminalSession) {
        let visible = model.selectedID == session.id && window?.isKeyWindow == true && NSApp.isActive
        guard !visible else { return }
        session.ringBell()
        if services.settings.settings.terminal.notifyOnBackgroundBell {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    // MARK: Strip actions

    private func makeActions() -> TabStripActions {
        TabStripActions(
            select: { [weak self] id in self?.session(id).map { self?.select($0) } },
            close: { [weak self] id in self?.session(id).map { self?.closeTab($0) } },
            newTab: { [weak self] in self?.coordinator?.openTab(in: self) },
            rename: { [weak self] id in self?.session(id).map { self?.rename($0) } },
            duplicate: { [weak self] id in
                guard let self, let session = self.session(id) else { return }
                self.coordinator?.duplicate(session, in: self)
            },
            reconnect: { [weak self] id in self?.session(id)?.restart() },
            moveToNewWindow: { [weak self] id in self?.session(id).map { self?.coordinator?.detach($0) } },
            closeOthers: { [weak self] id in
                guard let self else { return }
                self.model.sessions.filter { $0.id != id }.forEach { self.closeTab($0) }
            },
            move: { [weak self] id, target in
                guard let self else { return }
                self.coordinator?.moveSession(id, to: self, before: target)
            },
            installIntegration: { [weak self] id in self?.session(id).map { self?.installIntegration(for: $0) } },
            editHost: { [weak self] id in self?.session(id).map { self?.presentHostEditor(for: $0) } })
    }

    /// The tab's name as shown on the strip (using the saved host's current details).
    private func displayName(_ session: TerminalSession) -> String {
        TabItemState.firstLine(for: session, host: session.kind.host.flatMap { services.hosts.host(id: $0.id) })
    }

    /// Saves an SSH tab's destination as a host (keeping its id, so restore and shell
    /// integration recognise the open tab immediately), or edits the saved host.
    private func presentHostEditor(for session: TerminalSession) {
        guard let original = session.kind.host, let window else { return }
        let saved = services.hosts.host(id: original.id)
        let library = services.hosts
        let dismiss = { [weak window] in
            if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
        }
        let editor = HostEditorView(host: saved ?? original, isNew: saved == nil, services: services) { host in
            library.upsert(host)
            dismiss()
        } cancel: {
            dismiss()
        }
        window.beginSheet(NSWindow(contentViewController: NSHostingController(rootView: editor)))
    }

    /// Installs shell integration on an SSH tab's host, then offers a fresh tab that uses it.
    private func installIntegration(for session: TerminalSession) {
        guard let host = session.kind.host, let window else { return }
        Task {
            do {
                let report = try await RemoteIntegrationActions.install(host, services: services)
                let alert = NSAlert()
                alert.messageText = "Shell integration is ready on \(host.name)"
                alert.informativeText = report.summary + " New tabs to this host will use it."
                alert.addButton(withTitle: "Open New Tab")
                alert.addButton(withTitle: "Later")
                if await alert.beginSheetModal(for: window) == .alertFirstButtonReturn {
                    coordinator?.duplicate(session, in: self)
                }
            } catch {
                await NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    private func session(_ id: SessionID) -> TerminalSession? {
        model.sessions.first { $0.id == id }
    }

    private func rename(_ session: TerminalSession) {
        guard let window else { return }
        select(session)
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave empty to use the automatic title."
        let field = NSTextField(string: session.customTitle ?? "")
        field.placeholderString = displayName(session)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let title = field.stringValue.trimmingCharacters(in: .whitespaces)
            session.customTitle = title.isEmpty ? nil : title
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        coordinator?.didActivate(self)
        guard let session = selectedSession, let container = selectedContainer else { return }
        session.markSeen()
        container.focusTerminal()
        container.reassertSize()
    }

    func windowDidResize(_ notification: Notification) { root.updateTitlebarMetrics() }
    func windowDidEnterFullScreen(_ notification: Notification) { root.updateTitlebarMetrics() }
    func windowDidExitFullScreen(_ notification: Notification) { root.updateTitlebarMetrics() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let busy = model.sessions.filter(\.needsCloseConfirmation)
        guard !skipCloseConfirmation, services.settings.settings.terminal.confirmCloseWithRunningProcess, !busy.isEmpty else {
            return true
        }
        let alert = NSAlert()
        alert.messageText = model.sessions.count == 1 ? "Close this window?" : "Close \(model.sessions.count) tabs?"
        alert.informativeText = "\(busy.map { displayName($0) }.prefix(4).joined(separator: ", ")) \(busy.count == 1 ? "is" : "are") still running."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.skipCloseConfirmation = true
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        let closing = model.sessions
        containers.values.forEach { $0.teardown() }
        containers.removeAll()
        model.sessions.removeAll()
        coordinator?.windowWillClose(self, sessions: closing)
    }

    // MARK: Menu actions (responder chain)

    @objc func closeTab(_ sender: Any?) {
        if let session = selectedSession { closeTab(session) } else { window?.performClose(nil) }
    }

    @objc func showNextTab(_ sender: Any?) { stepTab(by: 1) }
    @objc func showPreviousTab(_ sender: Any?) { stepTab(by: -1) }

    private func stepTab(by offset: Int) {
        guard let current = model.sessions.firstIndex(where: { $0.id == model.selectedID }), model.sessions.count > 1 else { return }
        let next = (current + offset + model.sessions.count) % model.sessions.count
        select(model.sessions[next])
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        // ⌘9 is always the last tab, as in Safari and Terminal.
        let index = sender.tag == 9 ? model.sessions.count - 1 : sender.tag - 1
        guard model.sessions.indices.contains(index) else { return }
        select(model.sessions[index])
    }

    @objc func detachTab(_ sender: Any?) {
        if let session = selectedSession, model.sessions.count > 1 { coordinator?.detach(session) }
    }

    @objc func mergeAllTerminalWindows(_ sender: Any?) {
        coordinator?.mergeAll(into: self)
    }

    @objc func clearScrollback(_ sender: Any?) { selectedContainer?.terminal.clearScrollback() }
    @objc func biggerFont(_ sender: Any?) { selectedContainer?.changeFontSize(by: 1) }
    @objc func smallerFont(_ sender: Any?) { selectedContainer?.changeFontSize(by: -1) }
    @objc func defaultFontSize(_ sender: Any?) { selectedContainer?.changeFontSize(by: 0) }
    @objc func toggleFileBrowser(_ sender: Any?) { selectedContainer?.toggleFlyout() }
    @objc func reconnectSession(_ sender: Any?) { selectedSession?.restart() }
    @objc func renameTab(_ sender: Any?) { selectedSession.map(rename) }

    @objc func jumpToPreviousPrompt(_ sender: Any?) {
        guard let terminal = selectedContainer?.terminal, let row = terminal.previousSemanticPromptRow() else { return }
        terminal.scrollTo(row: row)
    }

    @objc func jumpToNextPrompt(_ sender: Any?) {
        guard let terminal = selectedContainer?.terminal, let row = terminal.nextSemanticPromptRow() else { return }
        terminal.scrollTo(row: row)
    }

    @objc func exportText(_ sender: Any?) {
        guard let window, let session = selectedSession, let container = selectedContainer else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(displayName(session)).txt"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try container.terminal.getBufferAsData(kind: .normal).write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(reconnectSession(_:)):
            menuItem.title = selectedSession?.kind.host != nil ? "Reconnect" : "Restart Shell"
            return selectedSession.map { !$0.state.isRunning } ?? false
        case #selector(toggleFileBrowser(_:)):
            menuItem.title = selectedContainer?.isFlyoutVisible == true ? "Hide Files" : "Show Files"
            return selectedContainer != nil
        case #selector(selectTabByNumber(_:)):
            return menuItem.tag == 9 ? !model.sessions.isEmpty : menuItem.tag <= model.sessions.count
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)), #selector(detachTab(_:)):
            return model.sessions.count > 1
        case #selector(mergeAllTerminalWindows(_:)):
            return (coordinator?.windowCount ?? 1) > 1
        default:
            return true
        }
    }

    private func contextMenuItems() -> [NSMenuItem] {
        let files = NSMenuItem(title: selectedContainer?.isFlyoutVisible == true ? "Hide Files" : "Show Files",
                               action: #selector(toggleFileBrowser(_:)), keyEquivalent: "")
        files.target = self
        let rename = NSMenuItem(title: "Rename Tab…", action: #selector(renameTab(_:)), keyEquivalent: "")
        rename.target = self
        return [.separator(), files, rename]
    }
}
