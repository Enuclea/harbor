import AppKit
import HarborCore
import HarborFiles
import HarborSessions
import HarborSSH
import SwiftTerm
import SwiftUI

/// The content of one tab: an optional blur behind a translucent terminal, a status
/// overlay, and the file flyout that slides in from the right.
@MainActor
final class TerminalContainerView: NSView {
    let terminal: HarborTerminalView
    let binding: TerminalSessionBinding
    private let session: TerminalSession
    private let services: AppServices
    private let overlayHost: NSHostingView<SessionOverlay>
    private var flyoutHost: NSView?
    private var flyoutModel: FileBrowserModel?
    private var flyoutTrailing: NSLayoutConstraint?
    private var paddingConstraints: [NSLayoutConstraint] = []
    private(set) var fontSizeDelta: CGFloat = 0

    static let flyoutWidth: CGFloat = 360

    init(session: TerminalSession, services: AppServices) {
        self.session = session
        self.services = services
        let settings = services.settings.settings
        let options = TerminalOptions(
            cols: settings.appearance.initialColumns, rows: settings.appearance.initialRows,
            termName: settings.terminal.termType, scrollback: settings.terminal.scrollbackLines)
        terminal = HarborTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 500),
            font: TerminalAppearance.font(for: settings.appearance, sizeDelta: 0), options: options)
        binding = TerminalSessionBinding(session: session, view: terminal, settings: services.settings)
        overlayHost = NSHostingView(rootView: SessionOverlay(session: session, actions: services.actions))
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        wantsLayer = true
        layout(settings: settings)
        applyAppearance()
        terminal.onFilesDropped = { [weak self] urls in self?.handleDrop(urls) ?? false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Layout

    private func layout(settings: AppSettings) {
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)

        overlayHost.sizingOptions = [.intrinsicContentSize]
        overlayHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlayHost)

        let padding = CGFloat(settings.appearance.contentPadding)
        paddingConstraints = [
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -max(2, padding - 4)),
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: max(4, padding / 2)),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -max(2, padding / 2)),
        ]
        NSLayoutConstraint.activate(paddingConstraints + [
            overlayHost.centerXAnchor.constraint(equalTo: centerXAnchor),
            overlayHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            overlayHost.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
    }

    /// The window content size that fits the configured columns × rows.
    var preferredContentSize: NSSize {
        let optimal = terminal.getOptimalFrameSize().size
        let padding = CGFloat(services.settings.settings.appearance.contentPadding)
        return NSSize(width: optimal.width + padding * 2, height: optimal.height + padding)
    }

    // MARK: Appearance

    func applyAppearance() {
        let settings = services.settings.settings
        let theme = services.theme(for: session)
        TerminalAppearance.apply(settings, theme: theme, sizeDelta: fontSizeDelta, to: terminal)
        // Window-level background, blur and appearance belong to the window's root view.
        let translucent = settings.appearance.backgroundOpacity < 0.999
        layer?.backgroundColor = translucent ? NSColor.clear.cgColor : theme.background.nsColor.cgColor
        let padding = CGFloat(settings.appearance.contentPadding)
        paddingConstraints[0].constant = padding
        paddingConstraints[1].constant = -max(2, padding - 4)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearance()
    }

    func changeFontSize(by delta: CGFloat) {
        fontSizeDelta = delta == 0 ? 0 : fontSizeDelta + delta
        applyAppearance()
    }

    // MARK: Focus

    func focusTerminal() {
        window?.makeFirstResponder(terminal)
    }

    /// Re-sends this view's grid size, e.g. after a browser resized the shared PTY.
    func reassertSize() {
        let dimensions = terminal.terminalDimensions
        session.resize(TerminalSize(columns: dimensions.cols, rows: dimensions.rows))
    }

    // MARK: File flyout

    var isFlyoutVisible: Bool { flyoutTrailing?.constant == 0 }

    func toggleFlyout() {
        if flyoutHost == nil { installFlyout() }
        guard let flyoutTrailing else { return }
        let show = flyoutTrailing.constant != 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            flyoutTrailing.animator().constant = show ? 0 : Self.flyoutWidth + 20
            layoutSubtreeIfNeeded()
        }
        if show {
            Task { await flyoutModel?.activate() }
        } else {
            focusTerminal()
        }
    }

    private func installFlyout() {
        let model = FileBrowserModel(session: session, services: services)
        let host = NSHostingView(rootView: FileBrowserPanel(model: model, onClose: { [weak self] in self?.toggleFlyout() }))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host, positioned: .above, relativeTo: terminal)
        let trailing = host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: Self.flyoutWidth + 20)
        NSLayoutConstraint.activate([
            trailing,
            host.widthAnchor.constraint(equalToConstant: Self.flyoutWidth),
            host.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            host.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        flyoutHost = host
        flyoutModel = model
        flyoutTrailing = trailing
        layoutSubtreeIfNeeded()
    }

    /// Files dropped on an SSH tab are uploaded to the remote directory; elsewhere their
    /// paths are typed, as in Terminal.app.
    private func handleDrop(_ urls: [URL]) -> Bool {
        guard session.kind.host != nil else { return false }
        if flyoutHost == nil { installFlyout() }
        if !isFlyoutVisible { toggleFlyout() }
        Task { await flyoutModel?.upload(urls) }
        return true
    }

    func teardown() {
        binding.detach()
        Task { await flyoutModel?.deactivate() }
    }
}
