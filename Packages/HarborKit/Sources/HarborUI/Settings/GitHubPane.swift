import AppKit
import HarborCore
import HarborHostSetup
import HarborSSH
import SwiftUI

struct GitHubPane: View {
    @Bindable var store: SettingsStore
    let services: AppServices
    @State private var sshKeys: [SSHKey] = []
    @State private var showingImportKeySheet = false
    @State private var selectedPlaybookForRun: ScriptPlaybook?
    @State private var selectedPlaybookForPreview: ScriptPlaybook?
    @State private var exportMessage: String?

    private var library: GitHubScriptLibrary { services.githubScripts }

    var body: some View {
        Form {
            repositorySection
            deployKeySection
            hygieneAndSplitSection
            scriptsSection
        }
        .formStyle(.grouped)
        .task {
            sshKeys = await services.keys.listKeys()
            library.reloadFromDisk()
        }
        .sheet(isPresented: $showingImportKeySheet) {
            ImportDeployKeySheet(library: library) {
                showingImportKeySheet = false
            }
        }
        .sheet(item: $selectedPlaybookForRun) { playbook in
            PlaybookRunnerSheet(playbook: playbook, store: store, services: services) {
                selectedPlaybookForRun = nil
            }
        }
        .sheet(item: $selectedPlaybookForPreview) { playbook in
            PlaybookSourcePreviewSheet(playbook: playbook) {
                selectedPlaybookForPreview = nil
            }
        }
    }

    // MARK: 1. Repository Configuration

    private var repositorySection: some View {
        Section("Closed GitHub Repository") {
            TextField(
                "Project URL",
                text: $store.settings.github.repositoryURL,
                prompt: Text("git@github.com:org/security-playbooks.git or https://github.com/org/repo")
            )
            if !store.settings.github.normalizedSSHURL.isEmpty,
               store.settings.github.normalizedSSHURL != store.settings.github.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines) {
                LabeledContent("SSH Clone URL") {
                    CodeText(store.settings.github.normalizedSSHURL)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                TextField("Branch / Tag", text: $store.settings.github.branch, prompt: Text("main"))
                TextField("Scripts Subfolder", text: $store.settings.github.scriptsSubdirectory, prompt: Text("Optional (e.g. scripts)"))
            }

            Toggle("Pull latest from GitHub before running a script on the fly", isOn: $store.settings.github.pullBeforeRun)
            Toggle("Automatically sync repository when Harbor launches", isOn: $store.settings.github.autoPullOnLaunch)

            HStack(spacing: 10) {
                Button {
                    Task { _ = try? await library.testConnection() }
                } label: {
                    Label("Test Read-Only Access", systemImage: "network")
                }
                .disabled(library.isSyncing || store.settings.github.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    Task { _ = try? await library.sync() }
                } label: {
                    Label("Pull Scripts Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(library.isSyncing || store.settings.github.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if library.isSyncing {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                if let commit = store.settings.github.lastSyncedCommit {
                    StatusBadge(text: "Synced @\(commit)", tone: .good)
                }
            }

            if let error = library.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let status = library.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 2. Read-Only SSH Deploy Key

    private var deployKeySection: some View {
        Section("Read-Only SSH Deploy Key") {
            Picker("Key Source", selection: $store.settings.github.keySource) {
                ForEach(GitHubSSHKeySource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }

            switch store.settings.github.keySource {
            case .keychainDeployKey:
                HStack {
                    if library.hasKeychainDeployKey {
                        StatusBadge(text: "Private key stored in Keychain", tone: .good)
                    } else {
                        StatusBadge(text: "No deploy key in Keychain", tone: .warning)
                    }
                    Spacer()
                    Button("Generate Read-Only Key") {
                        Task { _ = try? await library.generateReadOnlyDeployKey() }
                    }
                    Button("Paste Private Key…") {
                        showingImportKeySheet = true
                    }
                    if library.hasKeychainDeployKey {
                        Button("Clear", role: .destructive) {
                            library.removeDeployKey()
                        }
                    }
                }

                if !store.settings.github.deployPublicKey.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Public Key (add to GitHub → Repository → Settings → Deploy keys with 'Allow write access' UNCHECKED):")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            CodeText(store.settings.github.deployPublicKey)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            CopyButton(value: store.settings.github.deployPublicKey, label: "Copy Public Key")
                            if let url = store.settings.github.webDeployKeysURL {
                                Button("Open GitHub Deploy Keys ↗") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                }

                Footnote("The private SSH deploy key is stored exclusively in the macOS Keychain, materialized only as a temporary 0600 file while git fetches, and local git push is disabled (`no_push_readonly`).")

            case .sshKeyFile:
                Picker("SSH Key (~/.ssh)", selection: $store.settings.github.sshKeyPath) {
                    Text("Choose a key…").tag(String?.none)
                    ForEach(sshKeys) { key in
                        Text("\(key.fileName) (\(key.type))").tag(String?.some(key.privateKeyPath))
                    }
                }
                if let path = store.settings.github.sshKeyPath,
                   let key = sshKeys.first(where: { $0.privateKeyPath == path }) {
                    HStack {
                        CodeText(key.fingerprint).foregroundStyle(.secondary)
                        Spacer()
                        CopyButton(value: key.publicKey, label: "Copy Public Key")
                        if let url = store.settings.github.webDeployKeysURL {
                            Button("Open GitHub Deploy Keys ↗") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 3. #dnr (Do Not Release) & Secret Hygiene / Public Repo Split

    private var hygieneAndSplitSection: some View {
        let total = library.scripts.count
        let dnrScripts = library.scripts.filter(\.hasDNR)
        let secretWarnings = library.scripts.flatMap { script in
            script.secretWarnings.map { "\(script.relativePath): \($0)" }
        }

        return Section("Variables, Zero-Secrets & #dnr (Do Not Release) Policy") {
            HStack(spacing: 12) {
                StatusBadge(
                    text: "\(total) script\(total == 1 ? "" : "s")",
                    tone: total > 0 ? .good : .neutral
                )
                StatusBadge(
                    text: "\(dnrScripts.count) marked #dnr (private-only)",
                    tone: dnrScripts.isEmpty ? .good : .warning
                )
                StatusBadge(
                    text: secretWarnings.isEmpty ? "0 hardcoded secrets" : "\(secretWarnings.count) secret warning(s)",
                    tone: secretWarnings.isEmpty ? .good : .bad
                )
                Spacer()
                Button {
                    exportPublicCopy()
                } label: {
                    Label("Export Public-Safe Copy…", systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(library.scripts.isEmpty)
                .help("Exports a clean copy of the repository with all # @dnr files omitted and all #dnr lines/blocks stripped for public release.")
            }

            if !secretWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(secretWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            if let exportMessage {
                Text(exportMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Footnote("Convention: Parameterize scripts with `# @var: NAME=default \"Description\"` or `# @secret: NAME \"Description\"` instead of hardcoding values. Mark sensitive lines with `#dnr` (or blocks with `#dnr-start` / `#dnr-end`, or whole files with `# @dnr`) so they are automatically stripped when splitting out a public repository.")
        }
    }

    // MARK: 4. Checked-In Scripts Browser

    private var scriptsSection: some View {
        Section("Checked-In Scripts & Playbooks") {
            if library.scripts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No scripts loaded yet. Pull from your GitHub repository above, or seed Harbor's starter security & diagnostic templates to inspect the `# @var:` and `#dnr` format.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Load Starter Security & Audit Scripts") {
                            try? library.seedStarterTemplates()
                        }
                        Button("Open Local Checkout Folder") {
                            NSWorkspace.shared.open(services.paths.githubScripts)
                        }
                    }
                }
                .padding(.vertical, 4)
            } else {
                ForEach(library.scripts) { script in
                    ScriptPlaybookRow(
                        script: script,
                        onPreview: { selectedPlaybookForPreview = script },
                        onConfigureAndRun: { selectedPlaybookForRun = script }
                    )
                }
                HStack {
                    Button("Reload from Disk") {
                        library.reloadFromDisk()
                    }
                    Button("Seed Starter Templates") {
                        try? library.seedStarterTemplates()
                    }
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(services.paths.githubScripts)
                    }
                }
            }
        }
    }

    private func exportPublicCopy() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Public Copy"
        panel.message = "Choose a destination folder for the sanitized public repository copy (#dnr lines and files removed)."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let stats = try library.exportPublicSafeCopy(to: url)
                exportMessage = "Exported \(stats.exportedFiles) file(s) to \(url.lastPathComponent) (\(stats.omittedFiles) #dnr file(s) omitted, \(stats.strippedLines) #dnr line(s) stripped)."
            } catch {
                exportMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Row & Sheets

private struct ScriptPlaybookRow: View {
    let script: ScriptPlaybook
    let onPreview: () -> Void
    let onConfigureAndRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: script.category == "security" ? "lock.shield" : "terminal")
                    .foregroundStyle(.tint)
                Text(script.name)
                    .font(.body.weight(.semibold))
                Text(script.relativePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                if script.requiresSudo {
                    StatusBadge(text: "sudo", tone: .warning)
                }
                if script.isFileDNR {
                    StatusBadge(text: "#dnr file", tone: .bad)
                } else if !script.dnrLineNumbers.isEmpty {
                    StatusBadge(text: "#dnr (\(script.dnrLineNumbers.count) ln)", tone: .warning)
                }
                Button("Preview") { onPreview() }
                    .controlSize(.small)
                Button("Run / Stage…") { onConfigureAndRun() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            Text(script.summary)
                .font(.callout)
                .foregroundStyle(.secondary)

            if !script.variables.isEmpty {
                HStack(spacing: 6) {
                    Text("Variables:")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(script.variables) { variable in
                        Text(variable.isSecret ? "🔒 \(variable.name)" : "\(variable.name)=\(variable.defaultValue.isEmpty ? "…" : variable.defaultValue)")
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ImportDeployKeySheet: View {
    let library: GitHubScriptLibrary
    let onDone: () -> Void
    @State private var pem = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste Read-Only SSH Deploy Private Key")
                .font(.title3.weight(.semibold))
            Text("Paste an unencrypted OpenSSH private key (`-----BEGIN OPENSSH PRIVATE KEY-----`). Harbor stores it in the macOS Keychain and never writes it to `settings.json`.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $pem)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { onDone() }.keyboardShortcut(.cancelAction)
                Button("Save to Keychain") {
                    working = true
                    Task {
                        do {
                            _ = try await library.importDeployPrivateKey(pem)
                            pem = ""
                            onDone()
                        } catch {
                            self.error = error.localizedDescription
                            working = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(working || pem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct PlaybookSourcePreviewSheet: View {
    let playbook: ScriptPlaybook
    let onDone: () -> Void
    @State private var showPublicSanitized = false

    var body: some View {
        let raw = (try? playbook.loadContents()) ?? "# Unable to read script file"
        let display: String = {
            if showPublicSanitized {
                return ScriptPlaybook.sanitizeForPublicRelease(raw)
                    ?? "# Entire file is marked # @dnr (Do Not Release) and will be excluded from public repository splits."
            }
            return raw
        }()

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playbook.name).font(.title3.weight(.semibold))
                    Text(playbook.relativePath).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if playbook.hasDNR {
                    Toggle("Preview Public-Safe Split (#dnr stripped)", isOn: $showPublicSanitized)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            ScrollView {
                Text(display)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            .frame(minHeight: 300)

            HStack {
                if !playbook.dnrLineNumbers.isEmpty {
                    Text("#dnr lines: \(playbook.dnrLineNumbers.map(String.init).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                CopyButton(value: display, label: "Copy Script")
                Button("Close") { onDone() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 480)
    }
}

struct PlaybookRunnerSheet: View {
    let playbook: ScriptPlaybook
    @Bindable var store: SettingsStore
    let services: AppServices
    let onDone: () -> Void
    @State private var values: [String: String] = [:]
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: playbook.category == "security" ? "lock.shield.fill" : "play.Terminal")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playbook.name).font(.title3.weight(.semibold))
                    Text(playbook.summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if playbook.hasDNR {
                    StatusBadge(text: "#dnr private", tone: .warning)
                }
            }

            if playbook.variables.isEmpty {
                Text("This script uses no configurable environment variables.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Form {
                    Section("Runtime Variables (No Hardcoded Values)") {
                        ForEach(playbook.variables) { variable in
                            VStack(alignment: .leading, spacing: 3) {
                                if variable.isSecret {
                                    SecureField(
                                        "\(variable.name) (Secret — in-memory only)",
                                        text: binding(for: variable),
                                        prompt: Text(variable.summary.isEmpty ? "Secret value" : variable.summary)
                                    )
                                } else {
                                    TextField(
                                        variable.name,
                                        text: binding(for: variable),
                                        prompt: Text(variable.defaultValue.isEmpty ? variable.summary : "Default: \(variable.defaultValue)")
                                    )
                                }
                                if !variable.summary.isEmpty {
                                    Text(variable.summary)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(minHeight: 180, maxHeight: 280)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { onDone() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Stage in Active Tab") {
                    trigger(executeImmediately: false)
                }
                .disabled(working)

                Button(store.settings.github.pullBeforeRun && !store.settings.github.repositoryURL.isEmpty ? "Pull & Run in Active Tab" : "Run in Active Tab") {
                    trigger(executeImmediately: true)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(working)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            for variable in playbook.variables {
                if variable.isSecret {
                    values[variable.name] = services.githubScripts.sessionSecretValues[variable.name] ?? ""
                } else {
                    values[variable.name] = store.settings.github.variableDefaults[variable.name] ?? variable.defaultValue
                }
            }
        }
    }

    private func binding(for variable: ScriptVariable) -> Binding<String> {
        Binding(
            get: { values[variable.name] ?? variable.defaultValue },
            set: { newValue in
                values[variable.name] = newValue
                if variable.isSecret {
                    services.githubScripts.sessionSecretValues[variable.name] = newValue
                } else {
                    store.settings.github.variableDefaults[variable.name] = newValue
                }
            }
        )
    }

    private func trigger(executeImmediately: Bool) {
        working = true
        Task {
            if store.settings.github.pullBeforeRun,
               !store.settings.github.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try? await services.githubScripts.sync()
            }
            let refreshed = services.githubScripts.scripts.first(where: { $0.relativePath == playbook.relativePath }) ?? playbook
            services.actions?.runPlaybookInActiveTab(refreshed, variables: values, executeImmediately: executeImmediately)
            working = false
            onDone()
        }
    }
}
