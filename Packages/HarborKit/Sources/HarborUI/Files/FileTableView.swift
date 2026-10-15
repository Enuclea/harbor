import AppKit
import HarborFiles
import SwiftUI
import UniformTypeIdentifiers

/// The flyout's file list, in AppKit for native selection, keyboard handling and Finder
/// interoperability: remote files are dragged out as file promises (downloaded only when
/// dropped), and files dropped in are uploaded.
struct FileTableView: NSViewRepresentable {
    let model: FileBrowserModel
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, onClose: onClose) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTable()
        table.style = .plain
        table.backgroundColor = .clear
        table.headerView = nil
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.focusRingType = .none

        let name = NSTableColumn(identifier: .init("name"))
        name.resizingMask = .autoresizingMask
        table.addTableColumn(name)
        let size = NSTableColumn(identifier: .init("size"))
        size.width = 70
        size.minWidth = 60
        table.addTableColumn(size)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openClicked(_:))
        table.menu = context.coordinator.makeMenu()
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.onKey = { [weak coordinator = context.coordinator] event in coordinator?.handleKey(event) ?? false }
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.reloadIfNeeded(model.visibleEntries)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSFilePromiseProviderDelegate, NSMenuDelegate {
        let model: FileBrowserModel
        let onClose: () -> Void
        weak var table: NSTableView?
        private var rows: [FileEntry] = []
        private let promiseQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated
            return queue
        }()

        init(model: FileBrowserModel, onClose: @escaping () -> Void) {
            self.model = model
            self.onClose = onClose
        }

        func reloadIfNeeded(_ entries: [FileEntry]) {
            guard entries != rows else { return }
            rows = entries
            table?.reloadData()
        }

        private var selectedEntries: [FileEntry] {
            guard let table else { return [] }
            var indexes = table.selectedRowIndexes
            if table.clickedRow >= 0, !indexes.contains(table.clickedRow) { indexes = IndexSet(integer: table.clickedRow) }
            return indexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let entry = rows[row]
            let identifier = tableColumn?.identifier ?? .init("name")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? makeCell(identifier)
            if identifier.rawValue == "name" {
                cell.textField?.stringValue = entry.name
                cell.textField?.textColor = entry.isHidden ? .secondaryLabelColor : .labelColor
                cell.imageView?.image = Self.icon(for: entry)
                cell.toolTip = [entry.path, entry.permissionString, entry.modified?.formatted()].compactMap { $0 }.joined(separator: "\n")
            } else {
                cell.textField?.stringValue = entry.isDirectory ? "" : entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            }
            return cell
        }

        private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            if identifier.rawValue == "name" {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 18),
                    image.heightAnchor.constraint(equalToConstant: 18),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            } else {
                text.alignment = .right
                text.textColor = .secondaryLabelColor
                text.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            return cell
        }

        static func icon(for entry: FileEntry) -> NSImage {
            switch entry.kind {
            case .directory: return NSWorkspace.shared.icon(for: .folder)
            case .symlink: return NSWorkspace.shared.icon(for: .symbolicLink)
            default:
                let type = UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
                return NSWorkspace.shared.icon(for: type)
            }
        }

        // MARK: Actions

        @objc func openClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0, rows.indices.contains(table.clickedRow) else { return }
            let entry = rows[table.clickedRow]
            Task { await model.open(entry) }
        }

        /// The list keeps navigation keys; anything else is typing meant for the shell, so it
        /// goes to the terminal (and the terminal takes the keyboard back).
        func handleKey(_ event: NSEvent) -> Bool {
            switch event.keyCode {
            case 36, 76: // return, enter
                if let entry = selectedEntries.first { Task { await model.open(entry) } }
                return true
            case 51, 117: // delete, forward delete
                confirmDelete()
                return true
            case 53: // escape
                onClose()
                return true
            case 126 where event.modifierFlags.contains(.command): // ⌘↑
                Task { await model.goUp() }
                return true
            case _ where Self.tableKeys.contains(event.keyCode) || event.modifierFlags.contains(.command):
                return false
            default:
                model.returnFocusToTerminal(event)
                return true
            }
        }

        /// Arrows, Tab, Page Up/Down, Home and End.
        static let tableKeys: Set<UInt16> = [123, 124, 125, 126, 48, 116, 121, 115, 119]

        // MARK: Drag out

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            let entry = rows[row]
            guard model.isRemote else { return NSURL(fileURLWithPath: entry.path) }
            let type = entry.isDirectory ? UTType.folder : (UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
            provider.userInfo = entry
            return provider
        }

        nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            (filePromiseProvider.userInfo as? FileEntry)?.name ?? "download"
        }

        nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                             completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
            guard let entry = filePromiseProvider.userInfo as? FileEntry else {
                completionHandler(CocoaError(.fileNoSuchFile))
                return
            }
            Task { @MainActor [weak self] in
                guard let model = self?.model else {
                    completionHandler(CocoaError(.userCancelled))
                    return
                }
                do {
                    try await model.fulfilPromise(for: entry, at: url)
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }

        nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
            MainActor.assumeIsolated { promiseQueue }
        }

        // MARK: Drop in

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            if (info.draggingSource as? NSTableView) === tableView { return [] }
            guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
            if dropOperation == .on, rows.indices.contains(row), rows[row].isDirectory { return .copy }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            let target = dropOperation == .on && rows.indices.contains(row) && rows[row].isDirectory ? rows[row].path : nil
            Task { await model.upload(urls, into: target) }
            return true
        }

        // MARK: Context menu

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let selection = selectedEntries
            func add(_ title: String, _ action: Selector, enabled: Bool = true) {
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = self
                item.isEnabled = enabled
            }
            if !selection.isEmpty {
                add("Open", #selector(menuOpen))
                add(model.isRemote ? "Download to Downloads" : "Copy to Downloads", #selector(menuDownload))
                add("Download To…", #selector(menuDownloadTo))
                menu.addItem(.separator())
                add("Copy Path", #selector(menuCopyPath), enabled: selection.count == 1)
                if selection.count == 1, selection[0].isDirectory {
                    add("Change Terminal Directory Here", #selector(menuChangeDirectory), enabled: model.canChangeTerminalDirectory)
                }
                if !model.isRemote { add("Reveal in Finder", #selector(menuReveal)) }
                menu.addItem(.separator())
                add("Rename…", #selector(menuRename), enabled: selection.count == 1)
                add(model.isRemote ? "Delete…" : "Move to Trash…", #selector(menuDelete))
                menu.addItem(.separator())
            }
            add("New Folder…", #selector(menuNewFolder))
            add("Upload Files…", #selector(menuUpload))
            add("Refresh", #selector(menuRefresh))
        }

        @objc private func menuOpen() { selectedEntries.forEach { entry in Task { await model.open(entry) } } }
        @objc private func menuDownload() { model.download(selectedEntries, to: model.downloadsDirectory, reveal: true) }
        @objc private func menuCopyPath() { if let entry = selectedEntries.first { model.copyPath(entry) } }
        @objc private func menuChangeDirectory() { if let entry = selectedEntries.first { model.changeTerminalDirectory(to: entry.path) } }
        @objc private func menuReveal() {
            NSWorkspace.shared.activateFileViewerSelecting(selectedEntries.map { URL(fileURLWithPath: $0.path) })
        }
        @objc private func menuRefresh() { Task { await model.refresh() } }

        @objc private func menuDownloadTo() {
            let entries = selectedEntries
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Download"
            guard let window = table?.window else { return }
            panel.beginSheetModal(for: window) { [model] response in
                guard response == .OK, let url = panel.url else { return }
                MainActor.assumeIsolated { model.download(entries, to: url, reveal: true) }
            }
        }

        @objc private func menuUpload() {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.prompt = "Upload"
            guard let window = table?.window else { return }
            panel.beginSheetModal(for: window) { [model] response in
                guard response == .OK else { return }
                let urls = panel.urls
                Task { @MainActor in await model.upload(urls) }
            }
        }

        @objc private func menuRename() {
            guard let entry = selectedEntries.first else { return }
            prompt(title: "Rename “\(entry.name)”", value: entry.name, action: "Rename") { [model] name in
                Task { await model.rename(entry, to: name) }
            }
        }

        @objc private func menuNewFolder() {
            prompt(title: "New Folder", value: "untitled folder", action: "Create") { [model] name in
                Task { await model.makeFolder(named: name) }
            }
        }

        @objc private func menuDelete() { confirmDelete() }

        private func confirmDelete() {
            let entries = selectedEntries
            guard !entries.isEmpty, let window = table?.window else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = entries.count == 1 ? "Delete “\(entries[0].name)”?" : "Delete \(entries.count) items?"
            alert.informativeText = model.isRemote
                ? "This permanently deletes the items on \(model.title), including folder contents. It can't be undone."
                : "The items will be moved to the Trash."
            alert.addButton(withTitle: model.isRemote ? "Delete" : "Move to Trash").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [model] response in
                guard response == .alertFirstButtonReturn else { return }
                Task { @MainActor in await model.delete(entries) }
            }
        }

        private func prompt(title: String, value: String, action: String, completion: @escaping @MainActor (String) -> Void) {
            guard let window = table?.window else { return }
            let alert = NSAlert()
            alert.messageText = title
            let field = NSTextField(string: value)
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: action)
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                MainActor.assumeIsolated { completion(field.stringValue.trimmingCharacters(in: .whitespaces)) }
            }
        }
    }
}

/// Forwards key presses so the coordinator can handle Return, Delete and ⌘↑.
final class FileTable: NSTableView {
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}
