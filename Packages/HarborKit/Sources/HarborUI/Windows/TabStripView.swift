import AppKit
import HarborCore
import HarborSessions
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Per-window tab state observed by the strip.
@MainActor
@Observable
final class WindowTabsModel {
    var sessions: [TerminalSession] = []
    var selectedID: SessionID?
    /// The host library, so tabs show saved hosts' current names and colours.
    @ObservationIgnored weak var hosts: HostLibrary?
    /// Room left for the window buttons.
    var leadingInset: CGFloat = 80
    var isDark = true

    var items: [TabItemState] {
        sessions.map { session in
            let saved = session.kind.host.flatMap { hosts?.host(id: $0.id) }
            return TabItemState(session: session, isSelected: session.id == selectedID, savedHost: saved)
        }
    }
}

/// What the strip can ask its window to do.
struct TabStripActions: Sendable {
    var select: @MainActor @Sendable (SessionID) -> Void = { _ in }
    var close: @MainActor @Sendable (SessionID) -> Void = { _ in }
    var newTab: @MainActor @Sendable () -> Void = {}
    var rename: @MainActor @Sendable (SessionID) -> Void = { _ in }
    var duplicate: @MainActor @Sendable (SessionID) -> Void = { _ in }
    var reconnect: @MainActor @Sendable (SessionID) -> Void = { _ in }
    var moveToNewWindow: @MainActor @Sendable (SessionID) -> Void = { _ in }
    var closeOthers: @MainActor @Sendable (SessionID) -> Void = { _ in }
    /// Moves a tab (possibly from another window) before `target`, or to the end when nil.
    var move: @MainActor @Sendable (_ id: SessionID, _ target: SessionID?) -> Void = { _, _ in }
    var installIntegration: @MainActor @Sendable (SessionID) -> Void = { _ in }
    /// Opens the host editor: “Save as Host…” for unsaved destinations, “Edit Host…” otherwise.
    var editHost: @MainActor @Sendable (SessionID) -> Void = { _ in }
}

/// Live binding of the strip to a window's model.
struct TabStripView: View {
    let model: WindowTabsModel
    let actions: TabStripActions

    var body: some View {
        TabStripContent(items: model.items, leadingInset: model.leadingInset, actions: actions)
            .environment(\.colorScheme, model.isDark ? .dark : .light)
    }
}

/// The tab strip drawn in the title bar: one pill per session with a live status
/// indicator, a new-tab button, and empty space that drags the window.
struct TabStripContent: View {
    let items: [TabItemState]
    let leadingInset: CGFloat
    let actions: TabStripActions
    @State private var hovered: SessionID?
    @State private var dropTarget: DropSlot?

    static let tabSpacing: CGFloat = 5
    static let minimumTabWidth: CGFloat = 150
    static let maximumTabWidth: CGFloat = 270

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - leadingInset - 52)
            let fitted = items.isEmpty ? Self.maximumTabWidth
                : (available - CGFloat(items.count - 1) * Self.tabSpacing) / CGFloat(items.count)
            let width = min(Self.maximumTabWidth, max(Self.minimumTabWidth, fitted))
            let overflows = fitted < Self.minimumTabWidth

            HStack(spacing: 6) {
                if overflows {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) { tabs(width: width) }
                            .onAppear { scrollToSelection(proxy) }
                            .onChange(of: items.first(where: \.isSelected)?.id) { scrollToSelection(proxy) }
                    }
                } else {
                    tabs(width: width)
                }
                newTabButton
                Spacer(minLength: 0)
            }
            .padding(.leading, leadingInset)
            .padding(.trailing, 8)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onDrop(of: [.plainText], delegate: TabDropDelegate(target: .end, actions: actions, dropTarget: $dropTarget))
        }
        .background(WindowDragArea())
    }

    private func tabs(width: CGFloat) -> some View {
        HStack(spacing: Self.tabSpacing) {
            ForEach(items) { item in
                TabItemView(
                    item: item, width: width, isHovered: hovered == item.id,
                    showsInsertionMark: dropTarget == .before(item.id), actions: actions)
                    .id(item.id)
                    .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
                    .onDrop(of: [.plainText], delegate: TabDropDelegate(target: .before(item.id), actions: actions, dropTarget: $dropTarget))
            }
            if dropTarget == .end {
                Capsule().fill(Color.accentColor).frame(width: 2, height: 26)
            }
        }
        .padding(.vertical, 2)
    }

    private var newTabButton: some View {
        Button(action: actions.newTab) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("New Tab (⌘T)")
        .accessibilityLabel("New tab")
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        if let selected = items.first(where: \.isSelected)?.id {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(selected) }
        }
    }
}

/// One interactive tab: selection, close, rename/move menu, drag to reorder.
struct TabItemView: View {
    let item: TabItemState
    let width: CGFloat
    let isHovered: Bool
    let showsInsertionMark: Bool
    let actions: TabStripActions

    var body: some View {
        TabItemLabel(item: item, width: width, isHovered: isHovered, showsInsertionMark: showsInsertionMark) {
            actions.close(item.id)
        }
        .contentShape(Rectangle())
        .onTapGesture { actions.select(item.id) }
        .help(item.tooltip)
        .contextMenu { menu }
        .onDrag { NSItemProvider(object: TabDragPayload.encode(item.id) as NSString) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([item.title, item.subtitle, item.status.label].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(item.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Rename Tab…") { actions.rename(item.id) }
        Button("Duplicate Tab") { actions.duplicate(item.id) }
        if item.status == .exited || item.status == .failed {
            Button("Reconnect / Restart") { actions.reconnect(item.id) }
        }
        if let saved = item.hostSaved {
            Button(saved ? "Edit Host…" : "Save as Host…") { actions.editHost(item.id) }
        }
        if item.offersIntegrationInstall {
            Button("Install Shell Integration on This Host…") { actions.installIntegration(item.id) }
        }
        Divider()
        Button("Move to New Window") { actions.moveToNewWindow(item.id) }
        Divider()
        Button("Close Tab") { actions.close(item.id) }
        Button("Close Other Tabs") { actions.closeOthers(item.id) }
    }
}

/// How a tab looks: status, where (line 1) and what's running or last ran (line 2).
/// Pure SwiftUI, so it can be rendered offscreen for snapshot tests.
struct TabItemLabel: View {
    let item: TabItemState
    let width: CGFloat
    let isHovered: Bool
    let showsInsertionMark: Bool
    let close: () -> Void

    static let height: CGFloat = 40

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            SessionStatusIndicator(status: item.status)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: item.isSelected ? .semibold : .medium))
                        .foregroundStyle(item.isSelected ? Color.primary : Color.primary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.assistantActive {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.purple)
                    }
                }
                if let subtitle = item.subtitle {
                    subtitleLine(subtitle)
                }
            }
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 2) {
                closeButton
                if let since = item.busySince {
                    ElapsedLabel(since: since)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: width, height: Self.height)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(item.isSelected ? Color.primary.opacity(0.13) : Color.primary.opacity(isHovered ? 0.06 : 0))
        }
        .overlay {
            if item.isSelected {
                RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.08))
            }
        }
        .overlay(alignment: .bottom) {
            if let color = item.hostColor.color {
                Capsule().fill(color).frame(height: 2).padding(.horizontal, 12)
            }
        }
        .overlay(alignment: .leading) {
            if showsInsertionMark {
                Capsule().fill(Color.accentColor).frame(width: 2, height: 26).offset(x: -3)
            }
        }
    }

    private func subtitleLine(_ subtitle: String) -> some View {
        HStack(spacing: 4) {
            if item.commandByAssistant {
                Image(systemName: "sparkle")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.purple.opacity(0.8))
            }
            Text(subtitle)
                .font(.system(size: 10.5, design: item.subtitleIsCommand ? .monospaced : .default))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let code = item.failedExitCode {
                Text("exit \(code)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize()
            }
        }
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary.opacity(isHovered ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(isHovered || item.isSelected ? 1 : 0)
        .accessibilityLabel("Close \(item.title)")
    }
}

/// "2:14" after a command has run for a few seconds.
private struct ElapsedLabel: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = Int(context.date.timeIntervalSince(since))
            if seconds >= 3 {
                Text(Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3_600 ? .hourMinuteSecond : .minuteSecond)))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Drag and drop

enum DropSlot: Equatable {
    case before(SessionID)
    case end
}

enum TabDragPayload {
    static let prefix = "harbor-tab:"

    static func encode(_ id: SessionID) -> String { prefix + id.description }

    static func decode(_ text: String) -> SessionID? {
        guard text.hasPrefix(prefix) else { return nil }
        return SessionID(string: String(text.dropFirst(prefix.count)))
    }
}

/// Reorders tabs, and accepts tabs dragged from other Harbor windows.
struct TabDropDelegate: DropDelegate {
    let target: DropSlot
    let actions: TabStripActions
    @Binding var dropTarget: DropSlot?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        dropTarget = target
    }

    func dropExited(info: DropInfo) {
        if dropTarget == target { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let actions = actions
        let before: SessionID? = if case .before(let id) = target { id } else { nil }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let id = TabDragPayload.decode(text), id != before else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { actions.move(id, before) }
            }
        }
        return true
    }
}

/// Empty strip space behaves like a title bar: drag to move, double-click to zoom.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}
