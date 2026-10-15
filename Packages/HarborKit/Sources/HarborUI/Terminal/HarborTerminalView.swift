import AppKit
import HarborSSH
import SwiftTerm

/// SwiftTerm's view plus the Mac behaviours Terminal.app users expect: dropping files
/// inserts their escaped paths (or uploads them, in SSH tabs) and a full context menu.
final class HarborTerminalView: TerminalView {
    /// Called with dropped file URLs. Return true if handled (e.g. uploaded); otherwise
    /// their paths are typed into the terminal.
    var onFilesDropped: (([URL]) -> Bool)?
    /// Extra context-menu items supplied by the window (Show Files, Rename Tab…).
    var extraMenuItems: (() -> [NSMenuItem])?
    var copyOnSelect = false

    override init(frame: CGRect, font: NSFont?, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        if onFilesDropped?(urls) == true { return true }
        send(txt: urls.map { ShellQuoting.escapePath($0.path) }.joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
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
        if let selection = getSelection(), !selection.isEmpty, let url = URL(string: selection.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme == "http" || url.scheme == "https" {
            let open = NSMenuItem(title: "Open Link", action: #selector(openSelectedLink(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = url
            menu.addItem(open)
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Clear Scrollback", action: Selector(("clearScrollback:")), keyEquivalent: "k")
        for item in extraMenuItems?() ?? [] { menu.addItem(item) }
        return menu
    }

    @objc private func openSelectedLink(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }
}
