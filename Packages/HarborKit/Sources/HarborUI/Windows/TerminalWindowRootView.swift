import AppKit
import HarborCore
import SwiftUI

/// A terminal window's content: the tab strip in the title bar, the selected tab's
/// terminal below it, and the blur behind both when the window is translucent.
@MainActor
final class TerminalWindowRootView: NSView {
    let model: WindowTabsModel
    private let effectView = NSVisualEffectView()
    private let stripBackground = NSView()
    private let stripHost: NSHostingView<TabStripView>
    private let divider = NSView()
    private let contentArea = NSView()
    private var stripHeight: NSLayoutConstraint!
    private var containers: [ObjectIdentifier: NSView] = [:]

    /// Title bar height with the window's unified toolbar; the fallback for full screen.
    static let minimumStripHeight: CGFloat = 46
    /// Breathing room between the tabs and the first line of terminal text.
    static let gapBelowStrip: CGFloat = 4

    init(model: WindowTabsModel, actions: TabStripActions) {
        self.model = model
        stripHost = NSHostingView(rootView: TabStripView(model: model, actions: actions))
        // The strip sits inside the title bar, which SwiftUI treats as unsafe area: without
        // this it lays the tabs out *below* the strip, on top of the terminal text.
        stripHost.safeAreaRegions = []
        stripHost.clipsToBounds = true
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        wantsLayer = true

        effectView.blendingMode = .behindWindow
        effectView.material = .underWindowBackground
        effectView.state = .active
        stripBackground.wantsLayer = true
        divider.wantsLayer = true
        contentArea.wantsLayer = true
        for view in [effectView, stripBackground, contentArea, stripHost, divider] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        stripHeight = stripHost.heightAnchor.constraint(equalToConstant: 52)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stripHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            stripHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            stripHost.topAnchor.constraint(equalTo: topAnchor),
            stripHeight,

            stripBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            stripBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            stripBackground.topAnchor.constraint(equalTo: topAnchor),
            stripBackground.bottomAnchor.constraint(equalTo: stripHost.bottomAnchor),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.topAnchor.constraint(equalTo: stripHost.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            contentArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentArea.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: Self.gapBelowStrip),
            contentArea.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Tabs

    func add(_ container: NSView) {
        let key = ObjectIdentifier(container)
        guard containers[key] == nil else { return }
        containers[key] = container
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = true
        contentArea.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            container.topAnchor.constraint(equalTo: contentArea.topAnchor),
            container.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
        ])
    }

    func remove(_ container: NSView) {
        containers.removeValue(forKey: ObjectIdentifier(container))
        container.removeFromSuperview()
    }

    /// Shows one container; the others stay attached (their sessions keep running and
    /// keep the window's size) but hidden.
    func show(_ container: NSView) {
        for view in containers.values { view.isHidden = view !== container }
    }

    // MARK: Metrics and appearance

    /// Sizes the strip to the title bar and leaves room for the window buttons.
    func updateTitlebarMetrics() {
        guard let window else { return }
        let fullScreen = window.styleMask.contains(.fullScreen)
        let titlebar = window.frame.height - window.contentLayoutRect.height
        let height = fullScreen ? Self.minimumStripHeight : max(titlebar, Self.minimumStripHeight)
        if abs(stripHeight.constant - height) > 0.5 { stripHeight.constant = height }
        var inset: CGFloat = 12
        if !fullScreen, let zoom = window.standardWindowButton(.zoomButton), !zoom.isHidden {
            inset = zoom.convert(zoom.bounds, to: nil).maxX + 14
        }
        if abs(model.leadingInset - inset) > 0.5 { model.leadingInset = inset }
    }

    var stripHeightValue: CGFloat { stripHeight.constant + 1 + Self.gapBelowStrip }

    func applyAppearance(theme: TerminalTheme, settings: AppSettings) {
        let opacity = CGFloat(settings.appearance.backgroundOpacity)
        let translucent = opacity < 0.999
        effectView.isHidden = !(translucent && settings.appearance.backgroundBlur)
        effectView.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        // The strip uses the terminal's colour so the whole window reads as one surface.
        let stripColor = theme.background.nsColor.blended(withFraction: 0.06, of: theme.isDark ? .white : .black) ?? theme.background.nsColor
        stripBackground.layer?.backgroundColor = stripColor.withAlphaComponent(translucent ? opacity : 1).cgColor
        divider.layer?.backgroundColor = (theme.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.08).cgColor
        layer?.backgroundColor = translucent ? NSColor.clear.cgColor : theme.background.nsColor.cgColor
        model.isDark = theme.isDark
        if let window {
            window.isOpaque = !translucent
            window.backgroundColor = translucent ? .clear : theme.background.nsColor
            window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTitlebarMetrics()
    }
}
