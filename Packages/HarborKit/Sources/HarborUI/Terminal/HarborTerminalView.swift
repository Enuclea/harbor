import AppKit
import HarborSSH
import SwiftTerm

/// SwiftTerm's view plus the Mac behaviours Terminal.app users expect: dropping files
/// inserts their escaped paths (or uploads them, in SSH tabs) and a full context menu.
final class HarborTerminalView: TerminalView {
    static let remotePathPasteboardType = NSPasteboard.PasteboardType("dev.harbor.remote-path")

    /// Called with dropped file URLs and whether Option (⌥) was held. Return true if handled
    /// (e.g. uploaded); otherwise their paths are typed into the terminal.
    var onFilesDropped: (([URL], _ optionHeld: Bool) -> Bool)?
    /// Called when the user selects "Explain Selection with AI" from the context menu.
    var onExplainSelection: ((String) -> Void)?
    /// Extra context-menu items supplied by the window (Show Files, Rename Tab…).
    var extraMenuItems: (() -> [NSMenuItem])?
    var copyOnSelect = false

    override init(frame: CGRect, font: NSFont?, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
        registerForDraggedTypes([Self.remotePathPasteboardType, .fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if let paths = remotePaths(from: sender), !paths.isEmpty { return .copy }
        return fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let paths = remotePaths(from: sender), !paths.isEmpty {
            send(txt: paths.map { ShellQuoting.escapePath($0) }.joined(separator: " ") + " ")
            window?.makeFirstResponder(self)
            return true
        }
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        if onFilesDropped?(urls, optionHeld) == true { return true }
        send(txt: urls.map { ShellQuoting.escapePath($0.path) }.joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
    }

    private func remotePaths(from info: any NSDraggingInfo) -> [String]? {
        guard let raw = info.draggingPasteboard.string(forType: Self.remotePathPasteboardType) else { return nil }
        let paths = raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return paths.isEmpty ? nil : paths
    }

    private func fileURLs(from info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // MARK: Selection

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if copyOnSelect, selectionActive { copy(self) }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copyItem.isEnabled = selectionActive
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        if let selection = getSelection(), !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let url = URL(string: selection.trimmingCharacters(in: .whitespacesAndNewlines)),
               url.scheme == "http" || url.scheme == "https" {
                let open = NSMenuItem(title: "Open Link", action: #selector(openSelectedLink(_:)), keyEquivalent: "")
                open.target = self
                open.representedObject = url
                menu.addItem(open)
            }
            if onExplainSelection != nil {
                let explain = NSMenuItem(title: "Explain Selection with AI", action: #selector(explainSelectedText(_:)), keyEquivalent: "")
                explain.target = self
                explain.representedObject = selection
                menu.addItem(explain)
            }
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Clear Scrollback", action: #selector(TerminalWindowController.clearScrollback(_:)), keyEquivalent: "k")
        for item in extraMenuItems?() ?? [] { menu.addItem(item) }
        return menu
    }

    @objc private func openSelectedLink(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc private func explainSelectedText(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String {
            onExplainSelection?(text)
        }
    }
}

