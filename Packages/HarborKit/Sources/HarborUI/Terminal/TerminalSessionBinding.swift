import AppKit
import HarborCore
import HarborSessions
import SwiftTerm

/// Connects one `TerminalSession` to one SwiftTerm view.
///
/// Output goes straight from the PTY read queue into SwiftTerm's thread-safe feed,
/// with no main-thread hop. Input, resizes and bells come back the other way.
/// The binding also lets automation read exactly what is on screen.
@MainActor
final class TerminalSessionBinding: NSObject, TerminalViewDelegate, ScreenReading {
    let session: TerminalSession
    private weak var view: HarborTerminalView?
    private var subscription: UUID?
    private let settings: SettingsStore

    var onBell: (() -> Void)?

    init(session: TerminalSession, view: HarborTerminalView, settings: SettingsStore) {
        self.session = session
        self.view = view
        self.settings = settings
        super.init()
        let sender = view.feedSender
        subscription = session.pipeline.subscribe { data in
            sender.feed(byteArray: ArraySlice(data))
        }
        view.terminalDelegate = self
        session.screen = self
    }

    func detach() {
        if let subscription { session.pipeline.detach(subscription) }
        subscription = nil
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session.resize(TerminalSize(columns: newCols, rows: newRows))
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // Titles are parsed from the byte stream by the session itself.
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // The session tracks OSC 7 independently of the renderer.
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session.send(Data(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto", "ssh", "file":
            NSWorkspace.shared.open(url)
        default:
            let alert = NSAlert()
            alert.messageText = "Open “\(link)”?"
            alert.informativeText = "A program in this tab wants to open a link that isn't a web address."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    func bell(source: TerminalView) {
        let mode = settings.settings.terminal.bell
        if mode == .sound || mode == .soundAndVisual { NSSound.beep() }
        onBell?()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard settings.settings.terminal.allowClipboardWrite, let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        guard settings.settings.terminal.allowClipboardRead else { return nil }
        return NSPasteboard.general.string(forType: .string).map { Data($0.utf8) }
    }

    // MARK: ScreenReading

    func screenSnapshot(scrollbackLines: Int) -> ScreenSnapshot {
        guard let view else { return ScreenSnapshot(lines: [], scrollbackCount: 0, cursorRow: nil, cursorColumn: nil) }
        let state = view.terminalStateSnapshot()
        let rows = state.dimensions.rows
        let visible = view.visibleRowsText(0..<rows)
        var history: [String] = []
        if scrollbackLines > 0 {
            let buffer = String(decoding: view.getBufferAsData(kind: .normal), as: UTF8.self)
            var lines = buffer.components(separatedBy: "\n")
            if lines.last?.isEmpty == true { lines.removeLast() }
            history = Array(lines.dropLast(rows).suffix(scrollbackLines))
        }
        var trimmedVisible = visible
        while trimmedVisible.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { trimmedVisible.removeLast() }
        return ScreenSnapshot(
            lines: history + trimmedVisible, scrollbackCount: history.count,
            cursorRow: state.cursor.row, cursorColumn: state.cursor.col)
    }
}
