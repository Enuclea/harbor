import AppKit
import HarborAssist
import HarborCore
import HarborSessions
import HarborSSH
@preconcurrency import UserNotifications

/// Presents sessions as tabs in terminal windows, moves tabs between windows, and
/// reports visual order to automation.
@MainActor
final class WindowCoordinator: NSObject, SessionPresenting {
    private(set) var controllers: [TerminalWindowController] = []
    private(set) var recentlyClosed: [SessionSnapshot] = []
    private weak var activeController: TerminalWindowController?
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    var hasWindows: Bool { !controllers.isEmpty }
    var canReopenClosedTab: Bool { !recentlyClosed.isEmpty }
    /// Set while quitting, so windows closing on the way out aren't saved over the quit state.
    var isTerminating = false
    /// The frame for the next new window (a restored window's saved frame).
    var pendingFrame: CGRect?
    var windowCount: Int { controllers.count }

    /// Windows front to back.
    var controllersInOrder: [TerminalWindowController] {
        let front = NSApp.orderedWindows.compactMap { $0.windowController as? TerminalWindowController }
        return front + controllers.filter { controller in !front.contains { $0 === controller } }
    }

    var keyController: TerminalWindowController? {
        (NSApp.keyWindow?.windowController as? TerminalWindowController) ?? activeController ?? controllers.last
    }

    // MARK: SessionPresenting

    func present(_ session: TerminalSession, placement: SessionPlacement) {
        wireNotifications(for: session)
        if placement == .newTab, let target = keyController {
            target.adopt(session)
            target.window?.makeKeyAndOrderFront(nil)
            return
        }
        let reference = keyController
        let controller = makeController()
        controller.adopt(session)
        if let frame = pendingFrame.flatMap(Self.visibleFrame) {
            controller.window?.setFrame(frame, display: false)
        } else {
            position(controller, relativeTo: reference)
        }
        pendingFrame = nil
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func focus(_ session: TerminalSession) {
        guard let controller = controller(for: session), let window = controller.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        controller.select(session)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func dismiss(_ session: TerminalSession) {
        controller(for: session)?.closeTab(session, confirm: false)
    }

    func orderedSessionIDs() -> [SessionID] {
        controllersInOrder.flatMap { $0.sessions.map(\.id) }
    }

    func focusedSessionID() -> SessionID? {
        keyController?.selectedSession?.id
    }

    // MARK: Lookup

    func session(for id: SessionID?) -> TerminalSession? {
        id.flatMap { services.sessions.session($0) }
    }

    func controller(for session: TerminalSession) -> TerminalWindowController? {
        controllers.first { $0.contains(session) }
    }

    /// Selects a session's tab and returns its window, e.g. to attach a sheet to it.
    func reveal(_ id: SessionID?) -> NSWindow? {
        guard let id, let session = services.sessions.session(id), let controller = controller(for: session) else {
            return NSApp.keyWindow
        }
        controller.select(session)
        return controller.window
    }

    // MARK: Opening & Reopening

    /// ⌘T / the strip's “+”: a local shell, in the current folder when configured.
    func openTab(in controller: TerminalWindowController?) {
        let target = controller ?? keyController
        var directory: String?
        if services.settings.settings.terminal.newTabDirectory == .sameAsCurrent,
           let session = target?.selectedSession, session.kind == .localShell {
            directory = session.workingDirectory
        }
        if let target { activeController = target }
        services.sessions.open(.localShell, workingDirectory: directory, placement: hasWindows ? .newTab : .newWindow)
    }

    func duplicate(_ session: TerminalSession, in controller: TerminalWindowController) {
        activeController = controller
        var kind = session.kind
        // Use the saved host as it is now (it may have been edited, or gained integration).
        if case .ssh(let host) = kind, let saved = services.hosts.host(id: host.id) { kind = .ssh(saved) }
        let directory = kind == .localShell ? session.workingDirectory : nil
        services.sessions.open(kind, workingDirectory: directory, placement: .newTab)
    }

    @discardableResult
    func reopenLastClosedTab() -> TerminalSession? {
        guard let snapshot = recentlyClosed.popLast() else { return nil }
        let placement: SessionPlacement = hasWindows ? .newTab : .newWindow
        let session: TerminalSession?
        switch snapshot.kind {
        case .local:
            session = services.sessions.open(.localShell, workingDirectory: snapshot.workingDirectory, placement: placement)
        case .host(let id):
            if let host = services.hosts.host(id: id) {
                session = services.sessions.open(.ssh(host), placement: placement)
            } else {
                session = nil
            }
        case .destination(let host):
            session = services.sessions.open(.ssh(host), placement: placement)
        }
        session?.customTitle = snapshot.customTitle
        return session
    }

    func reconnectAllDisconnected() {
        for session in services.sessions.sessions where session.kind.host != nil && !session.state.isRunning {
            session.restart()
        }
    }

    // MARK: Moving tabs

    /// Reorders within a window, or moves a tab here from another window.
    func moveSession(_ id: SessionID, to target: TerminalWindowController, before targetID: SessionID?) {
        guard let session = services.sessions.session(id), let source = controller(for: session) else { return }
        let before = targetID.flatMap(services.sessions.session)
        if source === target {
            target.move(session, before: before)
            return
        }
        guard let container = source.release(session) else { return }
        let index = before.flatMap { anchor in target.sessions.firstIndex { $0 === anchor } }
        target.adopt(session, container: container, at: index)
        target.window?.makeKeyAndOrderFront(nil)
    }

    func detach(_ session: TerminalSession) {
        guard let source = controller(for: session), source.sessions.count > 1,
              let container = source.release(session) else { return }
        let controller = makeController()
        controller.adopt(session, container: container)
        controller.window?.setFrame(source.window?.frame.offsetBy(dx: 28, dy: -28) ?? .zero, display: false)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func mergeAll(into target: TerminalWindowController) {
        for source in controllers where source !== target {
            for session in source.sessions {
                guard let container = source.release(session) else { continue }
                target.adopt(session, container: container, select: false)
            }
        }
        target.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Callbacks from windows

    func didActivate(_ controller: TerminalWindowController) {
        activeController = controller
    }

    /// The user closed one tab.
    func tabWasClosed(_ session: TerminalSession) {
        if !isTerminating {
            recordClosedSession(session)
        }
        services.sessions.windowDidClose(for: session)
    }

    func windowWillClose(_ controller: TerminalWindowController, state: RestorableWindow) {
        controllers.removeAll { $0 === controller }
        if activeController === controller { activeController = controllers.last }
        // Closing the last window is how many people leave Harbor without quitting, so it's
        // remembered like a quit: the Dock icon or the next launch brings it back. (Closing
        // its last tab instead leaves nothing to remember.)
        if controllers.isEmpty, !isTerminating, services.settings.settings.terminal.restoreSessionsOnLaunch {
            let hosts = services.hosts
            SessionRestorer(paths: services.paths).save([state]) { hosts.host(id: $0) != nil }
        }
        for session in state.sessions {
            if !isTerminating {
                recordClosedSession(session)
            }
            services.sessions.windowDidClose(for: session)
        }
    }

    /// `frame`, if enough of it is on a connected screen to use (displays change between launches).
    static func visibleFrame(_ frame: CGRect) -> CGRect? {
        guard frame.width >= 200, frame.height >= 120,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersection(frame).width >= 100 && $0.visibleFrame.intersection(frame).height >= 60 })
        else { return nil }
        return frame
    }

    func applyAppearance() {
        controllers.forEach { $0.applyAppearance() }
    }

    // MARK: Notifications & History

    private func recordClosedSession(_ session: TerminalSession) {
        let kind: SessionSnapshot.Kind
        switch session.kind {
        case .localShell:
            kind = .local
        case .ssh(let host):
            kind = services.hosts.host(id: host.id) != nil ? .host(host.id) : .destination(host)
        case .command:
            return
        }
        let snapshot = SessionSnapshot(
            kind: kind,
            workingDirectory: kind == .local ? session.workingDirectory : nil,
            customTitle: session.customTitle
        )
        recentlyClosed.append(snapshot)
        if recentlyClosed.count > 10 {
            recentlyClosed.removeFirst(recentlyClosed.count - 10)
        }
    }

    private func wireNotifications(for session: TerminalSession) {
        session.onNotification = { [weak self, weak session] title, body in
            guard let self, let session else { return }
            self.postSystemNotification(title: title, body: body, sessionID: session.id)
        }
        session.onCommandCompleted = { [weak self, weak session] command, duration, exitCode in
            guard let self, let session else { return }
            self.handleCommandCompleted(command: command, duration: duration, exitCode: exitCode, in: session)
        }
        session.onFirstOutput = { [weak self] session in
            self?.probeRemoteSystemProfileIfNeeded(for: session)
        }
    }

    private func probeRemoteSystemProfileIfNeeded(for session: TerminalSession) {
        guard let host = session.kind.host else { return }
        let sshSettings = services.settings.settings.ssh
        let controlDir = services.paths.sshControl
        let executor = SSHCommandBuilder(settings: sshSettings, controlDirectory: controlDir).executor(for: host)
        Task { @MainActor [weak session] in
            // Give shell integration 400ms to emit HarborSysInfo first if installed; otherwise probe over ControlMaster.
            try? await Task.sleep(for: .milliseconds(400))
            guard let session, session.systemProfile == nil else { return }
            if let result = try? await executor(SystemProfile.remoteProbeCommand),
               result.succeeded,
               var profile = SystemProfile.decode(from: result.output) {
                if let cwd = session.workingDirectory { profile.cwd = cwd }
                session.systemProfile = profile
            }
        }
    }

    private func handleCommandCompleted(command: String?, duration: TimeInterval, exitCode: Int32?, in session: TerminalSession) {
        let terminalSettings = services.settings.settings.terminal
        guard terminalSettings.notifyOnLongCommandCompletion,
              duration >= Double(max(1, terminalSettings.longCommandThresholdSeconds))
        else { return }

        let isVisible = (keyController?.selectedSession?.id == session.id)
            && (keyController?.window?.isKeyWindow == true)
            && NSApp.isActive
        guard !isVisible else { return }

        session.ringBell()
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }

        let cmdLabel = command ?? "Command"
        let durationLabel = "\(Int(duration.rounded()))s"
        let failed = (exitCode ?? 0) != 0 && exitCode != 130
        let title = failed
            ? "Command failed (exit \(exitCode!)) in \(session.title)"
            : "Command finished in \(session.title)"
        let baseBody = "\(cmdLabel) (\(durationLabel))"

        if failed,
           services.settings.settings.ai.onboard.enabled,
           services.settings.settings.ai.onboard.smartBackgroundAlerts {
            let output = ContextBudgeter.extractLastCommandOutput(from: session.pipeline.replay)
            let context = AssistContext(
                shell: session.shellIntegration ?? "zsh",
                isRemote: session.kind.host != nil,
                hostLabel: session.kind.host?.destinationLabel,
                workingDirectory: session.workingDirectory,
                lastCommand: command,
                lastExitCode: exitCode,
                rawOutput: output
            )
            let assist = services.assist
            let sessionID = session.id
            Task { @MainActor [weak self] in
                if let summary = try? await assist.summarizeForAlert(context: context), !summary.isEmpty {
                    self?.postSystemNotification(title: title, body: "\(baseBody) — \(summary)", sessionID: sessionID)
                } else {
                    self?.postSystemNotification(title: title, body: baseBody, sessionID: sessionID)
                }
            }
        } else {
            postSystemNotification(title: title, body: baseBody, sessionID: session.id)
        }
    }

    private func postSystemNotification(title: String, body: String, sessionID: SessionID) {
        // UNUserNotificationCenter requires a valid app bundle identifier.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = ["sessionID": sessionID.description]
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    // MARK: Helpers

    private func makeController() -> TerminalWindowController {
        let controller = TerminalWindowController(services: services, coordinator: self)
        controllers.append(controller)
        activeController = controller
        return controller
    }

    /// Cascades from the previous window, or centres the first one. Call after the
    /// window has its size.
    private func position(_ controller: TerminalWindowController, relativeTo reference: TerminalWindowController?) {
        guard let window = controller.window else { return }
        if let anchor = reference?.window, anchor !== window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: anchor.frame.minX, y: anchor.frame.maxY)))
        } else {
            window.center()
        }
    }
}

