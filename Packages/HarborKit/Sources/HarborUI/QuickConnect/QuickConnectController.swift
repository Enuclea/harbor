import AppKit
import HarborCore
import HarborSSH
import SwiftUI

/// Spotlight-style host picker (⇧⌘K): type to fuzzy-search saved hosts, or type any
/// `user@host:port` and press Return.
@MainActor
final class QuickConnectController: NSObject, NSWindowDelegate {
    private var panel: QuickConnectPanel?
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func toggle() {
        if let panel, panel.isVisible {
            panel.close()
            return
        }
        show()
    }

    private func show() {
        let panel = QuickConnectPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        let view = QuickConnectView(library: services.hosts) { [weak self, weak panel] choice in
            panel?.close()
            self?.open(choice)
        } dismiss: { [weak panel] in
            panel?.close()
        }
        panel.contentView = NSHostingView(rootView: view)
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 280, y: frame.maxY - frame.height * 0.28 - 380))
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.panel = panel
    }

    private func open(_ choice: QuickConnectChoice) {
        switch choice {
        case .host(let host): services.actions?.connect(to: host)
        case .destination(let host): services.actions?.connect(to: host)
        case .localShell: services.actions?.openLocalTab(in: nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}

/// A panel that can take keyboard focus without a title bar.
final class QuickConnectPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

enum QuickConnectChoice {
    case host(HostProfile)
    case destination(HostProfile)
    case localShell
}

struct QuickConnectView: View {
    let library: HostLibrary
    let choose: (QuickConnectChoice) -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var results: [HostProfile] { Array(library.search(query).prefix(8)) }

    private var typedDestination: HostProfile? {
        guard !query.isEmpty, query.contains("@") || query.contains(".") || query.contains(":"),
              let host = try? SSHDestination.parse(query), HostProfileValidator.problems(in: host).isEmpty else { return nil }
        return host
    }

    private var rowCount: Int { results.count + (typedDestination == nil ? 0 : 1) + 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.title3)
                TextField("Connect to a host or type user@server", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { activate(highlighted) }
            }
            .padding(16)
            Divider().opacity(0.4)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, host in
                        row(index: index, icon: host.isFavorite ? "star.fill" : "server.rack", tint: host.color.color,
                            title: host.name, subtitle: host.destinationLabel)
                    }
                    if let typed = typedDestination {
                        row(index: results.count, icon: "arrow.right.circle", tint: .accentColor,
                            title: "Connect to \(typed.destinationLabel)", subtitle: "New SSH tab")
                    }
                    row(index: rowCount - 1, icon: "apple.terminal", tint: nil, title: "New Local Tab", subtitle: "⌘T")
                }
                .padding(8)
            }
        }
        .frame(width: 560, height: 380)
        .glassPanel(cornerRadius: 18)
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
        .onKeyPress(.downArrow) { highlighted = min(rowCount - 1, highlighted + 1); return .handled }
        .onKeyPress(.upArrow) { highlighted = max(0, highlighted - 1); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func row(index: Int, icon: String, tint: Color?, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint ?? .secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if index == highlighted { Text("↩").foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(index == highlighted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { activate(index) }
        .onHover { if $0 { highlighted = index } }
    }

    private func activate(_ index: Int) {
        if index < results.count {
            choose(.host(results[index]))
        } else if index == results.count, let typed = typedDestination {
            choose(.destination(typed))
        } else {
            choose(.localShell)
        }
    }
}
