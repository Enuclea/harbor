import AppKit
import Carbon
import HarborControl
import HarborCore
import HarborDoctor
import HarborLogging
import HarborSessions
import HarborShell
import HarborSSH

/// Something that can check for app updates (Sparkle, wired in by the app target).
@MainActor
public protocol UpdateChecking: AnyObject {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

/// The composition root: creates services, connects them, and owns app-level windows.
@MainActor
public final class HarborAppController: NSObject, AppActions, NSMenuItemValidation, NSMenuDelegate {
    let services: AppServices
    let windows: WindowCoordinator
    weak var updater: (any UpdateChecking)?

    private lazy var settingsWindow = SettingsWindowController(services: services)
    private lazy var quickConnect = QuickConnectController(services: services)
    private var onboarding: OnboardingWindowController?
    private var approvals: ApprovalPresenter?
    private var lastSettings: AppSettings
    private var appearanceObservation: NSKeyValueObservation?
    private var secureKeyboardEntry = false
    private let log = Log(.app)

    public init(updater: (any UpdateChecking)? = nil) {
        signal(SIGPIPE, SIG_IGN)
        services = AppServices(paths: .standard)
        windows = WindowCoordinator(services: services)
        lastSettings = services.settings.settings
        self.updater = updater
        super.init()
        services.actions = self
        services.sessions.presenter = windows
        let approvals = ApprovalPresenter(windows: windows)
        self.approvals = approvals
        services.control.approver = approvals
        services.settings.onSaveError = { [log] error in log.error("couldn't save settings", error: error) }
        services.hosts.onSaveError = { [log] error in log.error("couldn't save hosts", error: error) }
    }

    // MARK: Lifecycle

    func launch() {
        log.notice("\(AppIdentity.name) \(AppIdentity.version) (\(AppIdentity.build)) launching")
        NSApp.mainMenu = MainMenuBuilder.build(controller: self)
        installShellIntegration()
        applyPrompt()
        updateMCPService()
        Task { await services.remote.apply(services.settings.settings.remote) }
        services.settings.startWatchingForExternalChanges()
        observeSettings()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.windows.applyAppearance() }
        }

        restoreOrOpenFirstTab()
        if services.settings.settings.onboarding.needsOnboarding { showOnboarding() }
        if let issue = services.settings.loadIssue { showAlert("Settings were reset", issue) }
    }

    func shouldTerminate() -> NSApplication.TerminateReply {
        let busy = services.sessions.sessions.filter(\.needsCloseConfirmation)
        guard services.settings.settings.terminal.confirmCloseWithRunningProcess, !busy.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit \(AppIdentity.name)?"
        alert.informativeText = "\(busy.count) tab\(busy.count == 1 ? " is" : "s are") still running something (\(busy.prefix(3).map(\.title).joined(separator: ", "))). Quitting ends \(busy.count == 1 ? "it" : "them")."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func willTerminate() {
        windows.isTerminating = true
        let restorer = SessionRestorer(paths: services.paths)
        if !services.settings.settings.terminal.restoreSessionsOnLaunch {
            restorer.clear()
        } else if windows.hasWindows {
            let hosts = services.hosts
            restorer.save(windows.controllersInOrder.map(\.restorableState)) { hosts.host(id: $0) != nil }
        }
        // With no windows open, the file already holds the last window closed (or nothing,
        // if its tabs were closed one by one).
        services.sessions.sessions.forEach { $0.terminate() }
        services.settings.flush()
        services.mcp.stop()
        let remote = services.remote
        let done = DispatchSemaphore(value: 0)
        Task.detached { await remote.shutdown(); done.signal() }
        _ = done.wait(timeout: .now() + 2)
        services.fileLog.flush()
        if secureKeyboardEntry { DisableSecureEventInput() }
        log.notice("\(AppIdentity.name) quit")
    }

    /// The Dock icon was clicked with no windows open: bring back the last window closed (or
    /// the windows from the last quit), else open a fresh one.
    func reopen() {
        guard !windows.hasWindows else { return }
        if !restoreSavedWindows() { openLocalTab(in: nil, placement: .newWindow) }
    }

    /// `ssh://` links, `harbor://` links and folders dropped on the Dock icon.
    func open(_ urls: [URL]) {
        for url in urls {
            switch url.scheme?.lowercased() {
            case "ssh":
                do {
                    let host = try SSHDestination.parse(url.absoluteString)
                    try HostProfileValidator.validate(host)
                    services.sessions.open(.ssh(host))
                } catch {
                    showAlert("Can't open \(url.absoluteString)", error.localizedDescription)
                }
            case "harbor":
                handleHarborURL(url)
            case "file":
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                    openLocalTab(in: isDirectory.boolValue ? url.path : url.deletingLastPathComponent().path)
                }
            default:
                break
            }
        }
    }

    /// `harbor://connect/<host name or id>` and `harbor://settings/<section>`.
    private func handleHarborURL(_ url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host {
        case "connect":
            if let reference = parts.first,
               let host = services.hosts.hosts.first(where: { $0.id.description == reference || $0.name == reference }) {
                connect(to: host)
            }
        case "settings":
            openSettings(section: parts.first.flatMap(SettingsSection.init(rawValue:)))
        default:
            break
        }
    }

    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "").target = self
        let hosts = services.hosts.search("").prefix(8)
        if !hosts.isEmpty {
            menu.addItem(.separator())
            for host in hosts {
                let item = NSMenuItem(title: host.name, action: #selector(connectFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = host.id
                menu.addItem(item)
            }
        }
        return menu
    }

    // MARK: Settings reactions

    private func observeSettings() {
        withObservationTracking {
            _ = services.settings.settings
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.settingsChanged()
                self?.observeSettings()
            }
        }
    }

    private func settingsChanged() {
        let current = services.settings.settings
        let previous = lastSettings
        lastSettings = current
        if current.appearance != previous.appearance || current.terminal != previous.terminal {
            windows.applyAppearance()
        }
        if current.logging.level != previous.logging.level {
            LogHub.shared.minimumLevel = current.logging.level
        }
        if current.ai.mcpEnabled != previous.ai.mcpEnabled {
            updateMCPService()
        }
        if current.remote != previous.remote {
            Task { await services.remote.apply(current.remote) }
        }
        if current.shell.prompt != previous.shell.prompt || current.shell.promptScope != previous.shell.promptScope {
            applyPrompt()
        }
    }

    private func installShellIntegration() {
        do {
            try ShellIntegrationInstaller(layout: services.shellLayout).install()
        } catch {
            log.error("shell integration install failed", error: error)
        }
    }

    private func applyPrompt() {
        let shell = services.settings.settings.shell
        do {
            let changed = try PromptInstaller(layout: services.shellLayout, home: services.paths.home)
                .apply(scope: shell.promptScope, config: shell.prompt)
            if !changed.isEmpty { log.notice("prompt applied to \(changed.map(\.lastPathComponent).joined(separator: ", "))") }
        } catch {
            log.error("couldn't apply prompt", error: error)
        }
    }

    private func updateMCPService() {
        if services.settings.settings.ai.mcpEnabled {
            guard !services.mcpListening else { return }
            do {
                try services.mcp.start()
                services.mcpListening = true
            } catch {
                services.mcpListening = false
                log.error("MCP server didn't start", error: error)
            }
        } else if services.mcpListening {
            services.mcp.stop()
            services.mcpListening = false
        }
    }

    private func restoreOrOpenFirstTab() {
        if !restoreSavedWindows() { openLocalTab(in: nil, placement: .newWindow) }
    }

    /// Reopens the saved windows, each at its old frame with its old front tab, front window
    /// last so it ends up on top. Returns whether anything opened.
    @discardableResult
    private func restoreSavedWindows() -> Bool {
        guard services.settings.settings.terminal.restoreSessionsOnLaunch else { return false }
        let document = SessionRestorer(paths: services.paths).load()
        var opened = 0
        var currentWindow: Int?
        var windowTabs: [(snapshot: WindowSnapshot?, sessions: [TerminalSession])] = []
        for snapshot in document.sessions {
            let startsWindow = opened == 0 || snapshot.windowIndex != currentWindow
            currentWindow = snapshot.windowIndex
            let placement: SessionPlacement = startsWindow ? .newWindow : .newTab
            if startsWindow {
                windows.pendingFrame = document.window(snapshot.windowIndex)?.frame
                windowTabs.append((document.window(snapshot.windowIndex), []))
            }
            let session: TerminalSession?
            switch snapshot.kind {
            case .local:
                session = services.sessions.open(.localShell, workingDirectory: snapshot.workingDirectory, placement: placement)
            case .host(let id):
                session = services.hosts.host(id: id).map { services.sessions.open(.ssh($0), placement: placement) }
            case .destination(let host):
                session = HostProfileValidator.problems(in: host).isEmpty
                    ? services.sessions.open(.ssh(host), placement: placement) : nil
            }
            if session == nil { log.warning("couldn't restore a tab: \(snapshot.kind)") }
            session?.customTitle = snapshot.customTitle
            if let session {
                opened += 1
                windowTabs[windowTabs.count - 1].sessions.append(session)
            }
        }
        windows.pendingFrame = nil
        for (snapshot, sessions) in windowTabs {
            guard let index = snapshot?.selectedTab, sessions.indices.contains(index),
                  let controller = windows.controller(for: sessions[index]) else { continue }
            controller.select(sessions[index])
        }
        windowTabs.reversed().compactMap { $0.sessions.first.flatMap(windows.controller(for:)) }
            .forEach { $0.window?.makeKeyAndOrderFront(nil) }
        return opened > 0
    }

    // MARK: AppActions

    func openSettings(section: SettingsSection?) {
        settingsWindow.show(section)
    }

    func openLocalTab(in directory: String?) {
        openLocalTab(in: directory, placement: windows.hasWindows ? .newTab : .newWindow)
    }

    private func openLocalTab(in directory: String?, placement: SessionPlacement) {
        services.sessions.open(.localShell, workingDirectory: directory, placement: placement)
    }

    func connect(to host: HostProfile) {
        do {
            try HostProfileValidator.validate(host)
            services.sessions.open(.ssh(host), placement: windows.hasWindows ? .newTab : .newWindow)
        } catch {
            showAlert("Can't connect to \(host.name)", error.localizedDescription)
        }
    }

    func runInNewTab(_ command: CommandSpec, title: String) {
        services.sessions.open(.command(command, title: title), placement: windows.hasWindows ? .newTab : .newWindow)
    }

    func perform(_ remedy: Remedy) {
        RemedyPerformer(services: services).perform(remedy.action)
    }

    func showQuickConnect() {
        quickConnect.toggle()
    }

    func showOnboarding() {
        let controller = OnboardingWindowController(services: services) { [weak self] in self?.onboarding = nil }
        onboarding = controller
        controller.showWindow(nil)
        NSApp.activate()
    }

    func frontTerminalSize() -> TerminalSize? {
        windows.keyController?.selectedSession?.size
    }

    // MARK: Menu actions

    @objc func showSettings(_ sender: Any?) { openSettings(section: nil) }
    @objc func showHosts(_ sender: Any?) { openSettings(section: .hosts) }
    @objc func showDiagnostics(_ sender: Any?) { openSettings(section: .diagnostics) }
    @objc func showAssistants(_ sender: Any?) { openSettings(section: .assistants) }
    @objc func showRemoteAccess(_ sender: Any?) { openSettings(section: .remote) }
    @objc func showLogs(_ sender: Any?) { openSettings(section: .logs) }
    @objc func showQuickConnect(_ sender: Any?) { showQuickConnect() }

    @objc func newWindow(_ sender: Any?) {
        openLocalTab(in: nil, placement: .newWindow)
    }

    @objc func newTab(_ sender: Any?) {
        windows.openTab(in: windows.keyController)
    }

    @objc func connectFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? HostID, let host = services.hosts.host(id: id) { connect(to: host) }
    }

    @objc func toggleSecureKeyboardEntry(_ sender: Any?) {
        secureKeyboardEntry.toggle()
        if secureKeyboardEntry { EnableSecureEventInput() } else { DisableSecureEventInput() }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updater?.checkForUpdates()
    }

    @objc func exportSupportBundle(_ sender: Any?) {
        openSettings(section: .logs)
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleSecureKeyboardEntry(_:)):
            menuItem.state = secureKeyboardEntry ? .on : .off
            return true
        case #selector(checkForUpdates(_:)):
            return updater?.canCheckForUpdates ?? false
        default:
            return true
        }
    }

    /// Terminal windows use an empty toolbar only for its taller title bar, so drop the
    /// toolbar items AppKit adds to the View menu automatically.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        let toolbarActions: Set<Selector> = [#selector(NSWindow.toggleToolbarShown(_:)), #selector(NSWindow.runToolbarCustomizationPalette(_:))]
        for item in menu.items where item.action.map(toolbarActions.contains) == true {
            menu.removeItem(item)
        }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    }

    // MARK: Helpers

    private func sessionEnded(_ session: TerminalSession) {
        guard case .exited(let status) = session.state, !status.isClean, session.kind.host != nil else { return }
        log.info("ssh session to \(session.kind.host?.name ?? "?") ended: \(status)")
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
