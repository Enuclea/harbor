import AppKit
import HarborCore
@testable import HarborSessions
@testable import HarborUI
import Testing

/// Closing the last window remembers it (tabs, frame, front tab) the way quitting does.
@Suite("Window state", .serialized)
@MainActor
struct WindowStateTests {
    private let services: AppServices
    private let coordinator: WindowCoordinator

    init() {
        let root = FileManager.default.temporaryDirectory.appending(path: "harbor-state-\(UUID().uuidString)")
        services = AppServices(paths: AppPaths(applicationSupport: root.appending(path: "support"), logs: root.appending(path: "logs"),
                                               sshControl: root.appending(path: "cm"), home: root))
        coordinator = WindowCoordinator(services: services)
    }

    private func window(tabs: Int) -> (TerminalWindowController, [TerminalSession]) {
        let controller = TerminalWindowController(services: services, coordinator: coordinator)
        let sessions = (0..<tabs).map { _ in TerminalSession(kind: .localShell, configuration: nil) }
        sessions.forEach { controller.adopt($0) }
        return (controller, sessions)
    }

    @Test func closingTheLastWindowRemembersIt() throws {
        let (controller, sessions) = window(tabs: 2)
        controller.select(sessions[1])
        let frame = NSRect(x: 140, y: 90, width: 1100, height: 700)
        controller.window?.setFrame(frame, display: false)
        controller.window?.close()

        let document = SessionRestorer(paths: services.paths).load()
        #expect(document.sessions.map(\.kind) == [.local, .local])
        let window = try #require(document.window(0))
        #expect(window.frame == frame)
        #expect(window.selectedTab == 1)
    }

    @Test func closingTheLastTabLeavesNothingToReopen() {
        let (controller, sessions) = window(tabs: 1)
        controller.window?.close()
        #expect(!SessionRestorer(paths: services.paths).load().sessions.isEmpty)

        let (second, tabs) = window(tabs: 1)
        second.closeTab(tabs[0], confirm: false)
        #expect(SessionRestorer(paths: services.paths).load().sessions.isEmpty)
        _ = sessions
    }

    @Test func quittingDoesNotSaveOverTheQuitState() {
        let (controller, _) = window(tabs: 1)
        coordinator.isTerminating = true
        controller.window?.close()
        #expect(SessionRestorer(paths: services.paths).load().sessions.isEmpty)
    }

    @Test func ignoresFramesOffEveryScreen() throws {
        let screen = try #require(NSScreen.main).visibleFrame
        let onScreen = NSRect(x: screen.minX + 20, y: screen.minY + 20, width: 800, height: 500)
        #expect(WindowCoordinator.visibleFrame(onScreen) == onScreen)
        #expect(WindowCoordinator.visibleFrame(onScreen.offsetBy(dx: 100_000, dy: 0)) == nil, "a display that's gone")
        #expect(WindowCoordinator.visibleFrame(NSRect(x: screen.minX, y: screen.minY, width: 50, height: 50)) == nil)
    }

    @Test func newTabMenuListsFavouritesFirstThenByName() {
        let model = WindowTabsModel()
        model.hosts = services.hosts
        for host in [HostProfile(name: "web-10", hostname: "a"), HostProfile(name: "web-2", hostname: "b"),
                     HostProfile(name: "Nexus-TX", hostname: "c", isFavorite: true)] {
            services.hosts.upsert(host)
        }
        #expect(model.savedHosts.map(\.name) == ["Nexus-TX", "web-2", "web-10"])
    }
}
