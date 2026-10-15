import AppKit
import HarborCore
@testable import HarborSessions
@testable import HarborUI
import Testing

/// The file flyout must never get in the way of the terminal: it sits beside it, and the
/// terminal keeps (or gets back) the keyboard.
@Suite("File flyout", .serialized)
@MainActor
struct FileFlyoutTests {
    private let window: NSWindow
    private let container: TerminalContainerView
    private let root: URL

    init() {
        root = FileManager.default.temporaryDirectory.appending(path: "harbor-flyout-\(UUID().uuidString)")
        let paths = AppPaths(applicationSupport: root.appending(path: "support"), logs: root.appending(path: "logs"),
                             sshControl: root.appending(path: "cm"), home: root)
        let services = AppServices(paths: paths)
        container = TerminalContainerView(session: TerminalSession(kind: .localShell, configuration: nil), services: services)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        window.makeFirstResponder(container.terminal)
    }

    private func spin(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func fileTable() -> FileTable? {
        func search(_ view: NSView) -> FileTable? {
            if let table = view as? FileTable { return table }
            return view.subviews.lazy.compactMap(search).first
        }
        return search(container)
    }

    private func key(_ characters: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: code)!
    }

    @Test func opensBesideTheTerminalWithoutTakingTheKeyboard() throws {
        let fullWidth = container.terminal.frame.maxX
        container.toggleFlyout()
        #expect(container.isFlyoutVisible)

        // The terminal narrows at once (a single resize) to make room for the panel.
        let reserved = TerminalContainerView.flyoutWidth + TerminalContainerView.flyoutMargin * 2
        #expect(container.terminal.frame.maxX <= container.bounds.maxX - reserved)
        #expect(container.terminal.frame.maxX < fullWidth)
        spin { container.flyoutFrame.map { $0.maxX <= container.bounds.maxX } ?? false }
        let panel = try #require(container.flyoutFrame)
        #expect(container.terminal.frame.maxX < panel.minX, "the panel never covers terminal text")
        #expect(window.firstResponder === container.terminal, "you can keep typing while it's open")

        container.toggleFlyout()
        spin { container.terminal.frame.maxX >= fullWidth }
        #expect(container.terminal.frame.maxX == fullWidth, "closing gives the width back")
    }

    @Test func keepsANarrowWindowsTerminalUsable() {
        window.setContentSize(NSSize(width: 500, height: 400))
        container.layoutSubtreeIfNeeded()
        container.toggleFlyout()
        spin { container.flyoutFrame.map { $0.maxX <= container.bounds.maxX } ?? false }
        #expect(window.frame.width < 520, "opening the panel doesn't force the window wider")
        #expect((container.flyoutFrame?.width ?? .infinity) <= 500 * TerminalContainerView.flyoutMaximumShare + 0.5)
        #expect(container.terminal.frame.width >= 250)
    }

    @Test func typingInTheFileListGoesToTheTerminal() throws {
        container.toggleFlyout()
        container.layoutSubtreeIfNeeded()
        let table = try #require(fileTable())

        window.makeFirstResponder(table)
        table.keyDown(with: key("", code: 125)) // ↓ stays in the list
        #expect(window.firstResponder === table)

        table.keyDown(with: key("l", code: 37))
        #expect(window.firstResponder === container.terminal, "typing hands the keyboard back to the shell")

        window.makeFirstResponder(table)
        table.keyDown(with: key("\u{1b}", code: 53))
        #expect(!container.isFlyoutVisible, "Esc in the list closes the panel")
        #expect(window.firstResponder === container.terminal)
    }
}
