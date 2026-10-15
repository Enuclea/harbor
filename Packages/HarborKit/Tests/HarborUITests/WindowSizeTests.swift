import AppKit
import HarborCore
@testable import HarborSessions
@testable import HarborUI
import Testing

/// New windows open at the columns × rows set in Settings → General.
@Suite("New window size", .serialized)
@MainActor
struct WindowSizeTests {
    private func openWindow(columns: Int, rows: Int) -> (TerminalWindowController, TerminalContainerView?) {
        let root = FileManager.default.temporaryDirectory.appending(path: "harbor-size-\(UUID().uuidString)")
        let services = AppServices(paths: AppPaths(applicationSupport: root.appending(path: "support"), logs: root.appending(path: "logs"),
                                                   sshControl: root.appending(path: "cm"), home: root))
        services.settings.settings.appearance.initialColumns = columns
        services.settings.settings.appearance.initialRows = rows
        let controller = TerminalWindowController(services: services, coordinator: WindowCoordinator(services: services))
        controller.adopt(TerminalSession(kind: .localShell, configuration: nil))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return (controller, controller.selectedContainer)
    }

    @Test(arguments: [(132, 40), (80, 24), (100, 30)])
    func opensAtTheConfiguredGrid(columns: Int, rows: Int) throws {
        let (controller, container) = openWindow(columns: columns, rows: rows)
        defer { controller.window?.close() }
        let grid = try #require(container?.terminal.terminalDimensions)
        #expect(grid.cols == columns)
        #expect(grid.rows == rows)
    }
}
