import AppKit
import HarborCore
import HarborSessions

/// Presents sessions as native window tabs and reports their visual order.
@MainActor
final class WindowCoordinator: NSObject, SessionPresenting {
    private var controllers: [SessionID: TerminalWindowController] = [:]
    private let services: AppServices
    /// Window that new tabs join when there is no key terminal window (e.g. when an
    /// assistant opens a tab while Settings is frontmost).
    private weak var lastTerminalWindow: NSWindow?

    init(services: AppServices) {
        self.services = services
    }

    var hasWindows: Bool { !controllers.isEmpty }

    // MARK: SessionPresenting

    func present(_ session: TerminalSession, placement: SessionPlacement) {
        let controller = TerminalWindowController(session: session, services: services, coordinator: self)
        controllers[session.id] = controller
        guard let window = controller.window else { return }

        if placement == .newTab, let host = targetWindowForNewTab(), host !== window {
            host.addTabbedWindow(window, ordered: .above)
        } else if let reference = lastTerminalWindow {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: reference.frame.minX, y: reference.frame.maxY)))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        lastTerminalWindow = window
    }

    func focus(_ session: TerminalSession) {
        guard let window = controllers[session.id]?.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func dismiss(_ session: TerminalSession) {
        controllers[session.id]?.closeWithoutConfirmation()
    }

    func orderedSessionIDs() -> [SessionID] {
        var ordered: [SessionID] = []
        var seenGroups = Set<ObjectIdentifier>()
        for window in NSApp.orderedWindows {
            guard let controller = window.windowController as? TerminalWindowController else { continue }
            if let group = window.tabGroup {
                guard seenGroups.insert(ObjectIdentifier(group)).inserted else { continue }
                for tab in group.windows {
                    if let tabController = tab.windowController as? TerminalWindowController { ordered.append(tabController.session.id) }
                }
            } else {
                ordered.append(controller.session.id)
            }
        }
        // Minimised or hidden windows aren't in orderedWindows.
        let listed = Set(ordered)
        ordered += controllers.keys.filter { !listed.contains($0) }.sorted { $0.description < $1.description }
        return ordered
    }

    func focusedSessionID() -> SessionID? {
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? lastTerminalWindow
        return (window?.windowController as? TerminalWindowController)?.session.id
    }

    // MARK: Helpers

    var keyController: TerminalWindowController? {
        (NSApp.keyWindow?.windowController as? TerminalWindowController)
            ?? (lastTerminalWindow?.windowController as? TerminalWindowController)
    }

    private func targetWindowForNewTab() -> NSWindow? {
        if let key = NSApp.keyWindow, key.windowController is TerminalWindowController { return key }
        return lastTerminalWindow ?? controllers.values.first?.window
    }

    /// ⌘T / the tab bar's “+”: a local shell, in the same folder when configured.
    func openTab(nextTo controller: TerminalWindowController?) {
        let source = controller ?? keyController
        var directory: String?
        if services.settings.settings.terminal.newTabDirectory == .sameAsCurrent,
           let session = source?.session, session.kind == .localShell {
            directory = session.workingDirectory
        }
        if let window = source?.window { lastTerminalWindow = window }
        services.sessions.open(.localShell, workingDirectory: directory, placement: .newTab)
    }

    func windowDidClose(_ controller: TerminalWindowController) {
        controllers.removeValue(forKey: controller.session.id)
        if lastTerminalWindow === controller.window {
            lastTerminalWindow = controllers.values.compactMap(\.window).first
        }
        services.sessions.windowDidClose(for: controller.session)
    }

    func applyAppearance() {
        controllers.values.forEach { $0.applyAppearance() }
    }
}
