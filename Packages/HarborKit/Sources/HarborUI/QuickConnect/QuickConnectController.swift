import AppKit
import HarborCore
import HarborSessions
import HarborSSH
import SwiftUI

/// Spotlight-style universal switcher (`⇧⌘K`): jump to open tabs, fuzzy-search saved hosts,
/// reconnect to recent ad-hoc `user@host` destinations, or type any `user@host:port`.
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
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 420),
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
        let view = QuickConnectView(
            library: services.hosts,
            sessions: services.sessions.sessions,
            settings: services.settings,
            choose: { [weak self, weak panel] choice in
                panel?.close()
                self?.open(choice)
            },
            dismiss: { [weak panel] in
                panel?.close()
            }
        )
        panel.contentView = NSHostingView(rootView: view)
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 290, y: frame.maxY - frame.height * 0.26 - 420))
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.panel = panel
    }

    private func open(_ choice: QuickConnectChoice) {
        switch choice {
        case .openTab(let session):
            services.sessions.presenter?.focus(session)
        case .host(let host):
            services.actions?.connect(to: host)
        case .destination(let host):
            services.actions?.connect(to: host)
        case .localShell:
            services.actions?.openLocalTab(in: nil)
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
    case openTab(TerminalSession)
    case host(HostProfile)
    case destination(HostProfile)
    case localShell
}

struct QuickConnectView: View {
    let library: HostLibrary
    let sessions: [TerminalSession]
    @Bindable var settings: SettingsStore
    let choose: (QuickConnectChoice) -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private enum Entry: Identifiable {
        case openTab(TerminalSession)
        case savedHost(HostProfile)
        case recentDestination(HostProfile)
        case typedDestination(HostProfile)
        case localShell

        var id: String {
            switch self {
            case .openTab(let s): "tab-\(s.id.description)"
            case .savedHost(let h): "host-\(h.id.description)"
            case .recentDestination(let h): "recent-\(h.destinationLabel)"
            case .typedDestination(let h): "typed-\(h.destinationLabel)"
            case .localShell: "local-shell"
            }
        }
    }

    private var matchingTabs: [TerminalSession] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return Array(sessions.prefix(5))
        }
        return sessions.compactMap { session -> (TerminalSession, Int)? in
            let fields = [
                session.title,
                session.workingDirectory ?? "",
                session.lastCommandLine ?? "",
                session.kind.host?.destinationLabel ?? "",
            ]
            guard let best = fields.compactMap({ FuzzyMatcher.score(trimmed, in: $0) }).max() else {
                return nil
            }
            return (session, best)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(5)
        .map(\.0)
    }

    private var matchingHosts: [HostProfile] {
        Array(library.search(query).prefix(6))
    }

    private var matchingRecents: [HostProfile] {
        let savedLabels = Set(library.hosts.map(\.destinationLabel))
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return settings.settings.ssh.recentDestinations.filter { host in
            guard !savedLabels.contains(host.destinationLabel) else { return false }
            guard !trimmed.isEmpty else { return true }
            return FuzzyMatcher.score(trimmed, in: host.destinationLabel) != nil
        }
        .prefix(4)
        .map { $0 }
    }

    private var typedDestination: HostProfile? {
        guard !query.isEmpty, query.contains("@") || query.contains(".") || query.contains(":"),
              let host = try? SSHDestination.parse(query), HostProfileValidator.problems(in: host).isEmpty else { return nil }
        return host
    }

    private var entries: [Entry] {
        var list: [Entry] = []
        list.append(contentsOf: matchingTabs.map(Entry.openTab))
        list.append(contentsOf: matchingHosts.map(Entry.savedHost))
        list.append(contentsOf: matchingRecents.map(Entry.recentDestination))
        if let typed = typedDestination {
            list.append(.typedDestination(typed))
        }
        list.append(.localShell)
        return list
    }

    var body: some View {
        let currentEntries = entries
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.title3)
                TextField("Switch to open tab, search hosts, or type user@server", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { activate(highlighted, in: currentEntries) }
            }
            .padding(16)
            Divider().opacity(0.4)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(currentEntries.enumerated()), id: \.element.id) { index, entry in
                        entryRow(index: index, entry: entry, entries: currentEntries)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 580, height: 420)
        .glassPanel(cornerRadius: 18)
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(max(0, currentEntries.count - 1), highlighted + 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(0, highlighted - 1)
            return .handled
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    @ViewBuilder
    private func entryRow(index: Int, entry: Entry, entries: [Entry]) -> some View {
        switch entry {
        case .openTab(let session):
            let subtitle = [
                session.kind.host.map { "Open SSH tab · \($0.destinationLabel)" } ?? "Open tab",
                session.lastCommandLine,
                session.workingDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath }
            ].compactMap { $0 }.joined(separator: " · ")
            row(
                index: index,
                icon: session.kind.host != nil ? "rectangle.connected.to.line.below" : "terminal",
                tint: .green,
                title: session.title,
                subtitle: subtitle,
                badge: "Switch",
                entries: entries
            )
        case .savedHost(let host):
            row(
                index: index,
                icon: host.isFavorite ? "star.fill" : "server.rack",
                tint: host.color.color,
                title: host.name,
                subtitle: host.destinationLabel,
                badge: "Connect",
                entries: entries
            )
        case .recentDestination(let host):
            HStack(spacing: 8) {
                row(
                    index: index,
                    icon: "clock.arrow.circlepath",
                    tint: .secondary,
                    title: host.destinationLabel,
                    subtitle: "Recent SSH destination",
                    badge: "Connect",
                    entries: entries
                )
                Button("Save") {
                    library.upsert(host)
                }
                .controlSize(.small)
                .help("Save to Host Library")
                .padding(.trailing, 8)
            }
        case .typedDestination(let typed):
            row(
                index: index,
                icon: "arrow.right.circle",
                tint: .accentColor,
                title: "Connect to \(typed.destinationLabel)",
                subtitle: "New SSH tab",
                badge: "↩",
                entries: entries
            )
        case .localShell:
            row(
                index: index,
                icon: "apple.terminal",
                tint: nil,
                title: "New Local Tab",
                subtitle: "⌘T",
                badge: "↩",
                entries: entries
            )
        }
    }

    private func row(index: Int, icon: String, tint: Color?, title: String, subtitle: String, badge: String, entries: [Entry]) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint ?? .secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if index == highlighted {
                Text(badge)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(index == highlighted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { activate(index, in: entries) }
        .onHover { if $0 { highlighted = index } }
    }

    private func activate(_ index: Int, in entries: [Entry]) {
        guard entries.indices.contains(index) else { return }
        let commandHeld = NSEvent.modifierFlags.contains(.command)
        switch entries[index] {
        case .openTab(let session):
            if commandHeld, let host = session.kind.host {
                choose(.host(host))
            } else {
                choose(.openTab(session))
            }
        case .savedHost(let host):
            choose(.host(host))
        case .recentDestination(let host):
            choose(.destination(host))
        case .typedDestination(let typed):
            choose(.destination(typed))
        case .localShell:
            choose(.localShell)
        }
    }
}

