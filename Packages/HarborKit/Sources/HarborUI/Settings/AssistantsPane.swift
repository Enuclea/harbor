import HarborAssist
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

    // Onboard AI state
    @State private var apiKeyInput = ""
    @State private var hasStoredKey = false
    @State private var testingOnboard = false
    @State private var onboardTestStatus: String?
    @State private var onboardTestFailed = false
    @State private var prefixesText = ""

    private var onboard: Binding<OnboardAISettings> { $store.settings.ai.onboard }
    private var provider: AIProviderKind { store.settings.ai.onboard.provider }

    var body: some View {
        Form {
            onboardSection
            mcpSection
            connectSection
            permissionsSection
            activitySection
        }
        .formStyle(.grouped)
        .task {
            refreshKeyState()
            prefixesText = store.settings.ai.allowedCommandPrefixes.joined(separator: ", ")
            await refresh()
        }
        .onChange(of: store.settings.ai.onboard.provider) {
            apiKeyInput = ""
            onboardTestStatus = nil
            refreshKeyState()
        }
    }

    // MARK: Onboard AI Assist (Force Multiplier)

    private var onboardSection: some View {
        Section("Onboard AI Assist (Built-in Force Multiplier)") {
            Toggle("Enable built-in AI assist (⌘I, error parsing & smart alerts)", isOn: onboard.enabled)
            Footnote("Not an always-on agent — zero tokens are spent until you press ⌘I, click “Explain”, or a background job fails. Terminal output is stripped of ANSI codes, redacted for secrets, and capped to your token budget.")

            Picker("Provider", selection: onboard.provider) {
                ForEach(AIProviderKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }

            if provider.requiresAPIKey {
                LabeledContent("API Key") {
                    HStack(spacing: 8) {
                        SecureField(hasStoredKey ? "•••••••••••••••• (stored in Keychain)" : "Paste API key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                        Button("Save Key") { saveKey() }
                            .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if hasStoredKey {
                            StatusBadge(text: "Saved in Keychain", tone: .good)
                            Button("Clear") { clearKey() }
                        } else {
                            StatusBadge(text: "No key", tone: .neutral)
                        }
                    }
                }
            }

            TextField("Model", text: onboard.model, prompt: Text(provider.defaultModel))
            TextField("Endpoint URL", text: onboard.baseURL, prompt: Text(provider.defaultEndpoint))

            HStack {
                Button("Verify & Test API") {
                    Task { await testOnboardConnection() }
                }
                .disabled((provider.requiresAPIKey && !hasStoredKey && apiKeyInput.isEmpty) || testingOnboard)
                if testingOnboard {
                    ProgressView().controlSize(.small)
                } else if let onboardTestStatus {
                    Text(onboardTestStatus)
                        .font(.callout)
                        .foregroundStyle(onboardTestFailed ? .red : .green)
                }
                Spacer()
            }

            DisclosureGroup("Token Budget & Assist Triggers") {
                Stepper(value: onboard.maxContextTokens, in: 250...8_000, step: 250) {
                    LabeledContent("Max input context per request", value: "\(store.settings.ai.onboard.maxContextTokens.formatted()) tokens")
                }
                Stepper(value: onboard.maxOutputTokens, in: 100...2_000, step: 50) {
                    LabeledContent("Max response length", value: "\(store.settings.ai.onboard.maxOutputTokens.formatted()) tokens")
                }
                Toggle("Offer “Explain & Fix” chip when a command exits non-zero", isOn: onboard.offerOnCommandFailure)
                Toggle("Offer “Suggest Next Step” continuation chip after commands", isOn: onboard.offerContinuation)
                Toggle("Summarize failed background commands in desktop notifications", isOn: onboard.smartBackgroundAlerts)
                HStack {
                    let ledger = services.assist.ledger
                    Label(
                        "Session usage: \(ledger.totalTokens.formatted()) tokens (\(ledger.inputTokens.formatted()) in / \(ledger.outputTokens.formatted()) out across \(ledger.requestCount) calls)",
                        systemImage: "gauge.with.dots.needle.33percent"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    if ledger.requestCount > 0 {
                        Button("Reset Counter") { ledger.reset() }
                            .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: External MCP Assistants

    private var mcpSection: some View {
        Section("External Autonomous Agents (MCP)") {
            Toggle("Let external AI assistants use Harbor", isOn: $store.settings.ai.mcpEnabled)
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
    }

    private var connectSection: some View {
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
    }

    private var permissionsSection: some View {
        Section("What external assistants may do") {
            Toggle("Read what's on screen", isOn: $store.settings.ai.allowScreenReading)
            Picker("Type into tabs", selection: $store.settings.ai.inputPolicy) {
                ForEach(AIInputPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if store.settings.ai.inputPolicy == .askEveryTime || store.settings.ai.inputPolicy == .askOncePerTab {
                Toggle("Auto-approve safe read-only commands (ls, git status, rg…)", isOn: $store.settings.ai.autoAllowReadOnlyCommands)
                if store.settings.ai.autoAllowReadOnlyCommands {
                    TextField("Allowed prefixes", text: $prefixesText, prompt: Text("ls, pwd, git status, git diff, rg"))
                        .onSubmit { commitPrefixes() }
                        .onChange(of: prefixesText) { commitPrefixes() }
                    Footnote("Single-line commands starting with these prefixes run without a popup, unless they contain pipes, redirects, or command chaining (;, |, &, >, <, $()).")
                }
            }
            Toggle("Open tabs and connect to hosts", isOn: $store.settings.ai.allowOpeningTabs)
            Toggle("Close tabs", isOn: $store.settings.ai.allowClosingTabs)
            Toggle("Show when an assistant is acting on a tab", isOn: $store.settings.ai.showActivityIndicator)
            if store.settings.ai.inputPolicy == .allow {
                Footnote("Assistants can run any command without asking, with your permissions — on this Mac and on connected servers.")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var activitySection: some View {
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

    private func refreshKeyState() {
        hasStoredKey = services.assist.hasConfiguredKey(for: provider)
    }

    private func saveKey() {
        do {
            try services.assist.saveAPIKey(apiKeyInput, for: provider)
            apiKeyInput = ""
            refreshKeyState()
            onboardTestStatus = "Saved key to Keychain."
            onboardTestFailed = false
        } catch {
            onboardTestStatus = error.localizedDescription
            onboardTestFailed = true
        }
    }

    private func clearKey() {
        try? services.assist.removeAPIKey(for: provider)
        apiKeyInput = ""
        refreshKeyState()
        onboardTestStatus = nil
    }

    private func testOnboardConnection() async {
        if !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saveKey()
        }
        testingOnboard = true
        onboardTestStatus = nil
        do {
            let status = try await services.assist.testConnection()
            onboardTestStatus = status
            onboardTestFailed = false
        } catch {
            onboardTestStatus = error.localizedDescription
            onboardTestFailed = true
        }
        testingOnboard = false
    }

    private func commitPrefixes() {
        let parsed = prefixesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !parsed.isEmpty {
            store.settings.ai.allowedCommandPrefixes = parsed
        }
    }

    private func refresh() async {
        statuses = await services.mcpRegistry.status()
        activity = services.audit.recent(limit: 200).filter {
            $0.actor.hasPrefix("assistant:") || $0.actor.hasPrefix("onboard-ai:")
        }
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
