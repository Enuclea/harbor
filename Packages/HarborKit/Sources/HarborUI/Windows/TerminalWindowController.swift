import AppKit
import HarborCore
import HarborSessions
import SwiftUI
import UniformTypeIdentifiers

/// One window per session. Windows sharing a tab group are Terminal.app-style native tabs:
/// drag them out, merge them back, use Show All Tabs.
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    static let tabbingIdentifier = "HarborTerminal"

    let session: TerminalSession
    let container: TerminalContainerView
    private let services: AppServices
    private weak var coordinator: WindowCoordinator?
    private var skipCloseConfirmation = false

    init(session: TerminalSession, services: AppServices, coordinator: WindowCoordinator) {
        self.session = session
        self.services = services
        self.coordinator = coordinator
        container = TerminalContainerView(session: session, services: services)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.tabbingMode = .automatic
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 220)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = container
        window.setContentSize(container.preferredContentSize)
        window.tab.accessoryView = NSHostingView(rootView: TabAccessory(session: session))
        super.init(window: window)
        window.delegate = self

        container.binding.onBell = { [weak self] in self?.handleBell() }
        container.terminal.extraMenuItems = { [weak self] in self?.contextMenuItems() ?? [] }
        container.applyAppearance()
        updateTitle()
        observeSession()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Session observation

    private func observeSession() {
        withObservationTracking {
            _ = session.title
            _ = session.workingDirectory
            _ = session.state
            _ = session.size
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateTitle()
                self?.observeSession()
            }
        }
    }

    private func updateTitle() {
        guard let window else { return }
        window.title = session.title
        let size = "\(session.size.columns)×\(session.size.rows)"
        switch session.kind {
        case .ssh(let host):
            window.subtitle = "\(host.destinationLabel) — \(size)"
            window.representedURL = nil
        case .localShell, .command:
            if let directory = session.workingDirectory {
                window.subtitle = "\((directory as NSString).abbreviatingWithTildeInPath) — \(size)"
                window.representedURL = URL(fileURLWithPath: directory)
            } else {
                window.subtitle = size
            }
        }
    }

    private func handleBell() {
        guard let window, !window.isKeyWindow || !NSApp.isActive else { return }
        if services.settings.settings.terminal.notifyOnBackgroundBell {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func applyAppearance() {
        container.applyAppearance()
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        session.markSeen()
        container.focusTerminal()
        container.reassertSize()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !skipCloseConfirmation, services.settings.settings.terminal.confirmCloseWithRunningProcess,
              session.needsCloseConfirmation else { return true }
        let alert = NSAlert()
        alert.messageText = "Close this tab?"
        let process = session.foregroundProcessName ?? (session.kind.host != nil ? "ssh" : "a process")
        alert.informativeText = "Closing it will terminate \(process)."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.skipCloseConfirmation = true
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        container.teardown()
        coordinator?.windowDidClose(self)
    }

    /// Closes without asking (used when a session is closed programmatically).
    func closeWithoutConfirmation() {
        skipCloseConfirmation = true
        window?.close()
    }

    // MARK: Actions (responder chain)

    /// The tab bar's “+” button and ⌘T.
    @objc override func newWindowForTab(_ sender: Any?) {
        coordinator?.openTab(nextTo: self)
    }

    @objc func clearScrollback(_ sender: Any?) {
        container.terminal.clearScrollback()
    }

    @objc func biggerFont(_ sender: Any?) { container.changeFontSize(by: 1) }
    @objc func smallerFont(_ sender: Any?) { container.changeFontSize(by: -1) }
    @objc func defaultFontSize(_ sender: Any?) { container.changeFontSize(by: 0) }

    @objc func toggleFileBrowser(_ sender: Any?) {
        container.toggleFlyout()
    }

    @objc func reconnectSession(_ sender: Any?) {
        session.restart()
    }

    @objc func jumpToPreviousPrompt(_ sender: Any?) {
        if let row = container.terminal.previousSemanticPromptRow() { container.terminal.scrollTo(row: row) }
    }

    @objc func jumpToNextPrompt(_ sender: Any?) {
        if let row = container.terminal.nextSemanticPromptRow() { container.terminal.scrollTo(row: row) }
    }

    @objc func renameTab(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave empty to use the automatic title."
        let field = NSTextField(string: session.customTitle ?? "")
        field.placeholderString = session.title
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let title = field.stringValue.trimmingCharacters(in: .whitespaces)
            self?.session.customTitle = title.isEmpty ? nil : title
        }
    }

    @objc func exportText(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(session.title).txt"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let data = self.container.terminal.getBufferAsData(kind: .normal)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        let windows = window?.tabGroup?.windows ?? [window].compactMap { $0 }
        let index = sender.tag - 1
        guard windows.indices.contains(index) else { return }
        windows[index].makeKeyAndOrderFront(nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(reconnectSession(_:)):
            menuItem.title = session.kind.host != nil ? "Reconnect" : "Restart Shell"
            return !session.state.isRunning
        case #selector(toggleFileBrowser(_:)):
            menuItem.title = container.isFlyoutVisible ? "Hide Files" : "Show Files"
            return true
        case #selector(selectTabByNumber(_:)):
            let count = window?.tabGroup?.windows.count ?? 1
            return menuItem.tag <= count
        default:
            return true
        }
    }

    private func contextMenuItems() -> [NSMenuItem] {
        let files = NSMenuItem(title: container.isFlyoutVisible ? "Hide Files" : "Show Files",
                               action: #selector(toggleFileBrowser(_:)), keyEquivalent: "")
        files.target = self
        let rename = NSMenuItem(title: "Rename Tab…", action: #selector(renameTab(_:)), keyEquivalent: "")
        rename.target = self
        return [.separator(), files, rename]
    }
}
