import HarborCore
import HarborLogging
import HarborMCP
import SwiftUI

struct AssistantsPane: View {
    @Bindable var store: SettingsStore
    let services: AppServices
    @State private var statuses: [MCPClientStatus] = []
    @State private var working: MCPClientApp?
    @State private var errorMessage: String?
    @State private var activity: [AuditRecord] = []

    var body: some View {
        Form {
            Section {
                Toggle("Let AI assistants use Harbor", isOn: $store.settings.ai.mcpEnabled)
                LabeledContent("Server") {
                    if !store.settings.ai.mcpEnabled {
                        StatusBadge(text: "Off", tone: .neutral)
                    } else if services.mcpListening {
                        StatusBadge(text: "Listening", tone: .good)
                    } else {
                        StatusBadge(text: "Not listening", tone: .bad)
                    }
                }
                Footnote("Assistants connect through Harbor's MCP server (Model Context Protocol). They can list tabs, read the screen, run commands and open connections — within the limits below. Every action is logged.")
            }

            Section("Connect an assistant") {
                ForEach(MCPClientApp.allCases) { app in
                    AssistantRow(app: app, status: statuses.first { $0.app == app }, working: working == app) {
                        Task { await register(app) }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.callout)
                }
                DisclosureGroup("Other apps") {
                    Footnote("Add this to any MCP client's configuration:")
                    CodeText(services.mcpRegistry.genericSnippet)
                    CopyButton(value: services.mcpRegistry.genericSnippet, label: "Copy Configuration")
                }
            }

            Section("What assistants may do") {
                Toggle("Read what's on screen", isOn: $store.settings.ai.allowScreenReading)
                Picker("Type into tabs", selection: $store.settings.ai.inputPolicy) {
                    ForEach(AIInputPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Open tabs and connect to hosts", isOn: $store.settings.ai.allowOpeningTabs)
                Toggle("Close tabs", isOn: $store.settings.ai.allowClosingTabs)
                Toggle("Show when an assistant is acting on a tab", isOn: $store.settings.ai.showActivityIndicator)
                if store.settings.ai.inputPolicy == .allow {
                    Footnote("Assistants can run any command without asking, with your permissions — on this Mac and on connected servers.")
                        .foregroundStyle(.orange)
                }
            }

            Section("Recent activity") {
                if activity.isEmpty {
                    Text("No assistant activity yet.").foregroundStyle(.secondary)
                }
                ForEach(activity.prefix(30)) { record in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: record.outcome == .allowed ? "checkmark.circle" : "hand.raised")
                            .foregroundStyle(record.outcome == .allowed ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(record.actor.replacingOccurrences(of: "assistant:", with: "")) · \(record.action)")
                                .font(.callout)
                            if let detail = record.detail { CodeText(detail).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(record.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    private func refresh() async {
        statuses = await services.mcpRegistry.status()
        activity = services.audit.recent(limit: 200).filter { $0.actor.hasPrefix("assistant:") }
    }

    private func register(_ app: MCPClientApp) async {
        working = app
        errorMessage = nil
        do {
            try await services.mcpRegistry.register(app)
        } catch {
            errorMessage = error.localizedDescription
        }
        working = nil
        await refresh()
    }
}

private struct AssistantRow: View {
    let app: MCPClientApp
    let status: MCPClientStatus?
    let working: Bool
    let connect: () -> Void

    var body: some View {
        HStack {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.tint)
            Text(app.displayName)
            Spacer()
            if working {
                ProgressView().controlSize(.small)
            } else if let status {
                if status.isRegistered && !status.isStale {
                    StatusBadge(text: "Connected", tone: .good)
                } else if status.isStale {
                    Button("Update", action: connect)
                } else if status.isInstalled {
                    Button("Connect", action: connect)
                } else {
                    StatusBadge(text: "Not installed", tone: .neutral)
                }
            }
        }
    }

    private var icon: String {
        switch app {
        case .claudeDesktop: "bubble.left.and.text.bubble.right"
        case .claudeCode: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow.rays"
        case .codex: "terminal"
        }
    }
}
