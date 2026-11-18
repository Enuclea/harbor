import AppKit
import Observation
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general, appearance, prompt, hosts, keys, ssh, github, assistants, remote, logs, diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .prompt: "Prompt"
        case .hosts: "Hosts"
        case .keys: "SSH Keys"
        case .ssh: "SSH"
        case .github: "GitHub"
        case .assistants: "AI & MCP"
        case .remote: "Remote Access"
        case .logs: "Logs"
        case .diagnostics: "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .prompt: "chevron.right.square"
        case .hosts: "server.rack"
        case .keys: "key"
        case .ssh: "network"
        case .github: "arrow.triangle.branch"
        case .assistants: "sparkles"
        case .remote: "globe"
        case .logs: "list.bullet.rectangle"
        case .diagnostics: "stethoscope"
        }
    }

    /// Maps the section names used by Doctor remedies.
    init?(remedyName: String) {
        switch remedyName {
        case "terminal", "general": self = .general
        case "ai": self = .assistants
        default: self.init(rawValue: remedyName)
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var selection: SettingsSection = .general
}

/// The unified management window: settings, hosts, keys, AI, remote access, logs.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let navigation = SettingsNavigation()

    init(services: AppServices) {
        let root = SettingsRootView(services: services, navigation: navigation)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = "\(AppIdentityName.value) Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 940, height: 660))
        window.minSize = NSSize(width: 760, height: 480)
        window.setFrameAutosaveName("HarborSettings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ section: SettingsSection?) {
        if let section { navigation.selection = section }
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

enum AppIdentityName {
    static var value: String { "Harbor" }
}

struct SettingsRootView: View {
    let services: AppServices
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $navigation.selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .navigationTitle(navigation.selection.title)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .general: GeneralPane(store: services.settings, services: services)
        case .appearance: AppearancePane(store: services.settings)
        case .prompt: PromptPane(store: services.settings, services: services)
        case .hosts: HostsPane(library: services.hosts, services: services)
        case .keys: KeysPane(services: services)
        case .ssh: SSHPane(store: services.settings, services: services)
        case .github: GitHubPane(store: services.settings, services: services)
        case .assistants: AssistantsPane(store: services.settings, services: services)
        case .remote: RemoteAccessPane(store: services.settings, coordinator: services.remote, services: services)
        case .logs: LogsPane(store: services.settings, feed: services.logFeed, services: services)
        case .diagnostics: DiagnosticsPane(services: services)
        }
    }
}
