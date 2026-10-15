import HarborCore
import HarborSSH
import SwiftUI
import UniformTypeIdentifiers

struct KeysPane: View {
    let services: AppServices
    @State private var keys: [SSHKey] = []
    @State private var loading = true
    @State private var showingGenerator = false
    @State private var showingImporter = false
    @State private var agentKey: SSHKey?
    @State private var installKey: SSHKey?
    @State private var message: String?
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if keys.isEmpty {
                ContentUnavailableView {
                    Label("No SSH Keys", systemImage: "key")
                } description: {
                    Text("Create a modern Ed25519 key, or drop an existing private key here to import it.")
                } actions: {
                    Button("Generate Key…") { showingGenerator = true }.buttonStyle(.borderedProminent)
                    Button("Import Key…") { showingImporter = true }
                }
            } else {
                List(keys) { key in
                    KeyRow(key: key)
                        .contextMenu {
                            CopyButton(value: key.publicKey, label: "Copy Public Key")
                            Button("Add to Agent…") { agentKey = key }
                            Button("Install on Host…") { installKey = key }
                            Divider()
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: key.privateKeyPath)])
                            }
                        }
                }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).padding(8)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(8)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in await importKey(url) } }
                }
            }
            return true
        }
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { showingImporter = true } label: { Label("Import Key", systemImage: "square.and.arrow.down") }
                Button { showingGenerator = true } label: { Label("Generate Key", systemImage: "plus") }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data, .item]) { result in
            if case .success(let url) = result { Task { await importKey(url) } }
        }
        .sheet(isPresented: $showingGenerator) {
            KeyGeneratorView(services: services, existing: Set(keys.map(\.fileName))) { generated in
                showingGenerator = false
                if let generated { message = "Created \(generated.fileName)." }
                Task { await reload() }
            }
        }
        .sheet(item: $agentKey) { key in
            AddToAgentView(key: key, services: services) { result in
                agentKey = nil
                message = result
                Task { await reload() }
            }
        }
        .sheet(item: $installKey) { key in
            InstallKeyView(key: key, services: services) { installKey = nil }
        }
        .task { await reload() }
    }

    private func reload() async {
        keys = await services.keys.listKeys()
        loading = false
    }

    private func importKey(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let key = try await services.keys.importPrivateKey(from: url)
            message = "Imported \(key.fileName)."
        } catch {
            message = error.localizedDescription
        }
        await reload()
    }
}

private struct KeyRow: View {
    let key: SSHKey

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.horizontal.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(key.fileName).font(.body.weight(.medium))
                    Text("\(key.type)\(key.bits > 0 && key.type == "RSA" ? " \(key.bits)" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CodeText(key.fingerprint).foregroundStyle(.secondary)
                if !key.comment.isEmpty { Text(key.comment).font(.caption).foregroundStyle(.tertiary) }
            }
            Spacer()
            if key.isLoadedInAgent { StatusBadge(text: "In agent", tone: .good) }
            CopyButton(value: key.publicKey, label: "Copy Public Key")
        }
        .padding(.vertical, 4)
    }
}

private struct KeyGeneratorView: View {
    let services: AppServices
    let existing: Set<String>
    let done: (SSHKey?) -> Void
    @State private var name = "id_ed25519"
    @State private var comment = "\(NSUserName())@\(Host.current().localizedName ?? "mac")"
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var addToAgent = true
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Generate SSH Key").font(.title3.weight(.semibold))
            Form {
                TextField("File name", text: $name)
                TextField("Comment", text: $comment)
                SecureField("Passphrase", text: $passphrase, prompt: Text("Recommended"))
                SecureField("Confirm passphrase", text: $confirmation)
                Toggle("Add to agent and remember passphrase in Keychain", isOn: $addToAgent)
            }
            .formStyle(.grouped)
            Footnote("Harbor creates an Ed25519 key with ssh-keygen. The passphrase is typed into ssh-keygen directly and is never stored by Harbor.")
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Generate") { generate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || name.isEmpty || existing.contains(name) || passphrase != confirmation)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if existing.contains(name) { name = "id_ed25519_harbor" }
        }
    }

    private func generate() {
        working = true
        Task {
            do {
                let key = try await services.keys.generateKey(name: name, comment: comment, passphrase: passphrase.isEmpty ? nil : passphrase)
                if addToAgent {
                    try? await services.keys.addToAgent(key, passphrase: passphrase, storeInKeychain: services.settings.settings.ssh.storePassphrasesInKeychain)
                }
                passphrase = ""
                confirmation = ""
                done(key)
            } catch {
                self.error = error.localizedDescription
                working = false
            }
        }
    }
}

private struct AddToAgentView: View {
    let key: SSHKey
    let services: AppServices
    let done: (String?) -> Void
    @State private var passphrase = ""
    @State private var remember = true
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add \(key.fileName) to the SSH Agent").font(.headline)
            SecureField("Passphrase (leave empty if none)", text: $passphrase)
            Toggle("Remember in Keychain", isOn: $remember)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    working = true
                    Task {
                        do {
                            try await services.keys.addToAgent(key, passphrase: passphrase, storeInKeychain: remember)
                            done("\(key.fileName) is loaded in the agent.")
                        } catch {
                            done(error.localizedDescription)
                        }
                        passphrase = ""
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// Installs a public key on a host by running ssh-copy-id in a visible tab, so the user
/// answers the server's password prompt themselves.
private struct InstallKeyView: View {
    let key: SSHKey
    let services: AppServices
    let done: () -> Void
    @State private var hostID: HostID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install \(key.fileName) on a Host").font(.headline)
            Text("Harbor opens a tab running ssh-copy-id. If the server asks for a password, type it there. Afterwards, the key signs you in.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Host", selection: $hostID) {
                Text("Choose…").tag(HostID?.none)
                ForEach(services.hosts.hosts) { Text($0.name).tag(HostID?.some($0.id)) }
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Install") {
                    guard let hostID, let host = services.hosts.host(id: hostID) else { return }
                    let builder = SSHCommandBuilder(settings: services.settings.settings.ssh, controlDirectory: services.paths.sshControl)
                    services.actions?.runInNewTab(builder.installPublicKey(key.publicKeyPath, on: host), title: "Install key on \(host.name)")
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(hostID == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
