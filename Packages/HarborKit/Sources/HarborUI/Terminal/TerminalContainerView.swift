import AppKit
import HarborCore
import HarborFiles
import HarborSessions
import HarborSSH
import SwiftTerm
import SwiftUI

/// The content of one tab: an optional blur behind a translucent terminal, a status
/// overlay, and the file flyout that slides in from the right.
///
/// The flyout sits beside the terminal, never over it: opening it narrows the terminal
/// (one resize, so the shell redraws once) and the terminal keeps the keyboard, so you
/// can keep working while you browse.
@MainActor
final class TerminalContainerView: NSView {
    let terminal: HarborTerminalView
    let binding: TerminalSessionBinding
    private let session: TerminalSession
    private let services: AppServices
    private let overlayHost: NSHostingView<SessionOverlay>
    private var flyoutHost: NSView?
    private var flyoutModel: FileBrowserModel?
    /// The strip the flyout occupies; zero-width while it's hidden. The terminal ends at its leading edge.
    private let flyoutSlot = NSLayoutGuide()
    private var slotCollapsed: NSLayoutConstraint?
    private var slotFitsFlyout: NSLayoutConstraint?
    private var flyoutOnscreen: NSLayoutConstraint?
    private var flyoutOffscreen: NSLayoutConstraint?
    private var paddingConstraints: [NSLayoutConstraint] = []
    private(set) var fontSizeDelta: CGFloat = 0
    /// The text area for the configured columns × rows (Settings → General → New windows).
    private let configuredTerminalSize: NSSize

    static let flyoutWidth: CGFloat = 360
    /// The most of the tab the flyout may take, so a narrow window keeps a usable terminal.
    static let flyoutMaximumShare: CGFloat = 0.45
    static let flyoutMargin: CGFloat = 6

    init(session: TerminalSession, services: AppServices) {
        self.session = session
        self.services = services
        let settings = services.settings.settings
        let options = TerminalOptions(
            cols: settings.appearance.initialColumns, rows: settings.appearance.initialRows,
            termName: settings.terminal.termType, scrollback: settings.terminal.scrollbackLines)
        // A zero frame makes SwiftTerm keep the options' columns × rows; any other frame
        // recomputes the grid from it, which would lose the configured size.
        terminal = HarborTerminalView(
            frame: .zero, font: TerminalAppearance.font(for: settings.appearance, sizeDelta: 0), options: options)
        configuredTerminalSize = terminal.getOptimalFrameSize().size
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
        addLayoutGuide(flyoutSlot)

        let insets = Self.insets(padding: CGFloat(settings.appearance.contentPadding))
        paddingConstraints = [
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            terminal.trailingAnchor.constraint(equalTo: flyoutSlot.leadingAnchor, constant: -insets.right),
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ]
        let collapsed = flyoutSlot.widthAnchor.constraint(equalToConstant: 0)
        slotCollapsed = collapsed
        NSLayoutConstraint.activate(paddingConstraints + [
            collapsed,
            flyoutSlot.trailingAnchor.constraint(equalTo: trailingAnchor),
            flyoutSlot.topAnchor.constraint(equalTo: topAnchor),
            flyoutSlot.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlayHost.centerXAnchor.constraint(equalTo: terminal.centerXAnchor),
            overlayHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            overlayHost.widthAnchor.constraint(lessThanOrEqualTo: terminal.widthAnchor, constant: -16),
        ])
    }

    /// Space between the container's edges and the text grid for a padding setting.
    static func insets(padding: CGFloat) -> NSEdgeInsets {
        NSEdgeInsets(top: max(4, padding / 2), left: padding, bottom: max(2, padding / 2), right: max(2, padding - 4))
    }

    /// The content size that fits the configured columns × rows. Half a point of slack
    /// keeps rounding from costing the last row or column.
    var preferredContentSize: NSSize {
        let insets = Self.insets(padding: CGFloat(services.settings.settings.appearance.contentPadding))
        return NSSize(width: configuredTerminalSize.width + insets.left + insets.right + 0.5,
                      height: configuredTerminalSize.height + insets.top + insets.bottom + 0.5)
    }

    // MARK: Appearance

    func applyAppearance() {
        let settings = services.settings.settings
        let theme = services.theme(for: session)
        TerminalAppearance.apply(settings, theme: theme, sizeDelta: fontSizeDelta, to: terminal)
        // Window-level background, blur and appearance belong to the window's root view.
        let translucent = settings.appearance.backgroundOpacity < 0.999
        layer?.backgroundColor = translucent ? NSColor.clear.cgColor : theme.background.nsColor.cgColor
        let insets = Self.insets(padding: CGFloat(settings.appearance.contentPadding))
        paddingConstraints[0].constant = insets.left
        paddingConstraints[1].constant = -insets.right
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

    private(set) var isFlyoutVisible = false
    var flyoutFrame: NSRect? { flyoutHost?.frame }

    func toggleFlyout() {
        if flyoutHost == nil { installFlyout() }
        isFlyoutVisible.toggle()
        // The terminal changes width in one step, so the shell redraws once rather than on
        // every animation frame; only the panel slides.
        setSlotOpen(isFlyoutVisible)
        slideFlyout(onscreen: isFlyoutVisible)
        if isFlyoutVisible {
            Task { await flyoutModel?.activate() }
        } else {
            focusTerminal()
        }
    }

    private func setSlotOpen(_ open: Bool) {
        slotCollapsed?.isActive = !open
        slotFitsFlyout?.isActive = open
        layoutSubtreeIfNeeded()
    }

    private func slideFlyout(onscreen: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            flyoutOffscreen?.isActive = !onscreen
            flyoutOnscreen?.isActive = onscreen
            layoutSubtreeIfNeeded()
        }
    }

    private func installFlyout() {
        let model = FileBrowserModel(session: session, services: services)
        model.returnFocusToTerminal = { [weak self] event in
            guard let self else { return }
            self.focusTerminal()
            if let event { self.terminal.keyDown(with: event) }
        }
        let host = NSHostingView(rootView: FileBrowserPanel(model: model, onClose: { [weak self] in
            if self?.isFlyoutVisible == true { self?.toggleFlyout() }
        }))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host, positioned: .above, relativeTo: terminal)
        // Below the window's own size priority: the panel narrows to fit rather than
        // forcing the window wider.
        let width = host.widthAnchor.constraint(equalToConstant: Self.flyoutWidth)
        width.priority = .dragThatCannotResizeWindow
        let offscreen = host.leadingAnchor.constraint(equalTo: trailingAnchor, constant: Self.flyoutMargin)
        flyoutOffscreen = offscreen
        flyoutOnscreen = host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.flyoutMargin)
        slotFitsFlyout = flyoutSlot.widthAnchor.constraint(equalTo: host.widthAnchor, constant: Self.flyoutMargin * 2)
        NSLayoutConstraint.activate([
            width,
            host.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: Self.flyoutMaximumShare),
            host.topAnchor.constraint(equalTo: topAnchor, constant: Self.flyoutMargin),
            host.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.flyoutMargin),
            offscreen,
        ])
        flyoutHost = host
        flyoutModel = model
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
