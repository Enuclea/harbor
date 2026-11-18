import HarborCore
import HarborSSH
import SwiftUI

struct HostsPane: View {
    let library: HostLibrary
    let services: AppServices
    @State private var query = ""
    @State private var editorTarget: EditorTarget?
    @State private var importCandidates: [SSHConfigEntry]?
    @State private var selection: HostID?

    private enum EditorTarget: Identifiable {
        case create(HostProfile)
        case edit(HostID)

        var id: String {
            switch self {
            case .create(let host): "new-\(host.id.description)"
            case .edit(let id): "edit-\(id.description)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if library.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No Hosts Yet", systemImage: "server.rack")
                } description: {
                    Text("Save the machines you connect to and open them in one click — from here, Quick Connect (⇧⌘K), the Dock menu, or an AI assistant.")
                } actions: {
                    Button("Add Host…") { editorTarget = .create(HostProfile(name: "", hostname: "")) }
                        .buttonStyle(.borderedProminent)
                    Button("Import from ~/.ssh/config…") { loadImportCandidates() }
                }
            } else {
                List(selection: $selection) {
                    ForEach(library.search(query)) { host in
                        HostRow(host: host, onEdit: { editorTarget = .edit(host.id) })
                            .tag(host.id)
                    }
                }
                .contextMenu(forSelectionType: HostID.self) { ids in
                    if let id = ids.first, let host = library.host(id: id) {
                        menu(for: host)
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let host = library.host(id: id) {
                        services.actions?.connect(to: host)
                    }
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Filter hosts")
        .toolbar {
            ToolbarItemGroup {
                if let selection, library.host(id: selection) != nil {
                    Button { editorTarget = .edit(selection) } label: { Label("Edit Host", systemImage: "slider.horizontal.3") }
                        .help("Edit selected host")
                }
                Button { loadImportCandidates() } label: { Label("Import from SSH config", systemImage: "square.and.arrow.down") }
                    .help("Import hosts from ~/.ssh/config")
                Button { editorTarget = .create(HostProfile(name: "", hostname: "")) } label: { Label("Add Host", systemImage: "plus") }
                    .help("Add a host")
            }
        }
        .sheet(item: $editorTarget) { target in
            switch target {
            case .create(let draft):
                HostEditorView(host: draft, isNew: true, services: services) { saved in
                    services.saveAndSyncHost(saved)
                    editorTarget = nil
                } cancel: {
                    editorTarget = nil
                }
            case .edit(let id):
                if let current = library.host(id: id) {
                    HostEditorView(host: current, isNew: false, services: services) { saved in
                        services.saveAndSyncHost(saved)
                        editorTarget = nil
                    } cancel: {
                        editorTarget = nil
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { importCandidates != nil }, set: { if !$0 { importCandidates = nil } })) {
            SSHConfigImportView(candidates: importCandidates ?? [], library: library) { importCandidates = nil }
        }
    }

    @ViewBuilder
    private func menu(for host: HostProfile) -> some View {
        Button("Connect") {
            if let fresh = library.host(id: host.id) {
                services.actions?.connect(to: fresh)
            }
        }
        Button("Edit…") { editorTarget = .edit(host.id) }
        Button("Duplicate") {
            guard var copy = library.host(id: host.id) else { return }
            copy.id = HostID()
            copy.name += " copy"
            library.upsert(copy)
        }
        Button(host.isFavorite ? "Remove from Favourites" : "Add to Favourites") {
            guard var updated = library.host(id: host.id) else { return }
            updated.isFavorite.toggle()
            library.upsert(updated)
        }
        Divider()
        Button("Delete", role: .destructive) { library.remove(id: host.id) }
    }

    private func loadImportCandidates() {
        let existing = Set(library.hosts.map(\.hostname))
        importCandidates = SSHConfigParser.load(from: services.paths.sshConfig, sshDirectory: services.paths.sshDirectory)
            .filter { !existing.contains($0.alias) }
    }
}

private struct HostRow: View {
    let host: HostProfile
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((host.color.color ?? .secondary).opacity(0.18))
                    .frame(width: 34, height: 34)
                Image(systemName: host.isFavorite ? "star.fill" : "server.rack")
                    .foregroundStyle(host.color.color ?? .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).font(.body.weight(.medium))
                Text(host.usesSSHConfigAlias ? "\(host.hostname) (ssh config)" : host.destinationLabel)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !host.portForwards.isEmpty {
                let activeCount = host.portForwards.filter(\.autoStart).count
                let badgeText = host.portForwards.count == 1
                    ? host.portForwards[0].displaySummary
                    : "\(host.portForwards.count) redirects"
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption2.weight(.semibold))
                    Text(badgeText)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
                .foregroundStyle(activeCount > 0 ? Color.teal : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background((activeCount > 0 ? Color.teal : Color.secondary).opacity(0.15), in: Capsule())
                .help("Configured redirects: " + host.portForwards.map(\.displaySummary).joined(separator: ", "))
            }
            ForEach(host.tags.prefix(3), id: \.self) { tag in
                Text(tag).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            if let last = host.lastConnected {
                Text(last, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary)
            }
            Button {
                onEdit()
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Edit \(host.name)…")
        }
        .padding(.vertical, 4)
    }
}

struct HostEditorView: View {
    @State var host: HostProfile
    let isNew: Bool
    let services: AppServices
    let save: (HostProfile) -> Void
    let cancel: () -> Void
    @State private var tags = ""
    @State private var newForwardKind: PortForwardKind = .local
    @State private var newLocalPort = ""
    @State private var newRemotePort = ""
    @State private var socksPortText = "1080"
    @State private var newForwardError: String?
    @State private var reachability: Bool?
    @State private var testing = false

    init(host: HostProfile, isNew: Bool, services: AppServices, save: @escaping (HostProfile) -> Void, cancel: @escaping () -> Void) {
        _host = State(initialValue: host)
        _tags = State(initialValue: host.tags.joined(separator: ", "))
        if let existingSocks = host.portForwards.first(where: { $0.kind == .dynamic }) {
            _socksPortText = State(initialValue: String(existingSocks.listenPort))
        }
        self.isNew = isNew
        self.services = services
        self.save = save
        self.cancel = cancel
    }

    private var problems: [HostProfileProblem] { HostProfileValidator.problems(in: host) }

    private var namePreview: String {
        let name = HostProfile.promptSafe(host.name.trimmingCharacters(in: .whitespaces).isEmpty ? host.hostname : host.name)
        let user = host.user.flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        return "The tab and prompt read “\(user)@\(name)” instead of the server's hostname. The prompt follows on new "
            + "connections once Harbor's shell integration is installed or updated on the host (right-click its tab)."
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Connection") {
                    TextField("Name", text: $host.name, prompt: Text(host.hostname.isEmpty ? "Production API" : host.hostname))
                    Toggle("Show this name in the prompt and tab", isOn: $host.showsNameInPrompt)
                    if host.showsNameInPrompt { Footnote(namePreview) }
                    TextField("Host", text: $host.hostname, prompt: Text("server.example.com or an ssh config alias"))
                    Toggle("Use matching ~/.ssh/config entry", isOn: $host.usesSSHConfigAlias)
                    TextField("User", text: .optionalString($host.user), prompt: Text(NSUserName()))
                    TextField("Port", value: $host.port, format: .number.grouping(.never), prompt: Text("22"))
                    TextField("Jump host", text: .optionalString($host.jumpHost), prompt: Text("user@bastion.example.com"))
                }
                Section("Authentication") {
                    TextField("Identity file", text: .optionalString($host.identityFile), prompt: Text("Agent or ~/.ssh/config default"))
                    Toggle("Forward SSH agent", isOn: $host.forwardAgent)
                    Footnote("Only forward your agent to hosts you trust: their administrators can use your keys while you're connected.")
                }
                Section("Session") {
                    TextField("Run on connect", text: .optionalString($host.startupCommand), prompt: Text("e.g. tmux new -As main"))
                    TextField("File browser opens in", text: .optionalString($host.remoteDirectory), prompt: Text("Home folder"))
                }
                Section("Redirects & Proxies") {
                    LabeledContent("SOCKS5 proxy (-D)") {
                        HStack(spacing: 6) {
                            Text("localhost:")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            TextField("", text: $socksPortText, prompt: Text("1080"))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                                .frame(width: 68)
                                .onChange(of: socksPortText) { _, newValue in
                                    let cleaned = newValue.replacingOccurrences(of: ",", with: "")
                                    if cleaned != newValue {
                                        socksPortText = cleaned
                                        return
                                    }
                                    if let port = Int(cleaned.trimmingCharacters(in: .whitespaces)),
                                       PortForwardRule.isValidPort(port),
                                       let idx = host.portForwards.firstIndex(where: { $0.kind == .dynamic }) {
                                        host.portForwards[idx].listenPort = port
                                    }
                                }
                            Toggle("", isOn: Binding(
                                get: { host.portForwards.contains { $0.kind == .dynamic && $0.autoStart } },
                                set: { enabled in
                                    host.portForwards.removeAll { $0.kind == .dynamic }
                                    if enabled {
                                        let port = Int(socksPortText.trimmingCharacters(in: .whitespaces)) ?? 1080
                                        let validPort = PortForwardRule.isValidPort(port) ? port : 1080
                                        socksPortText = String(validPort)
                                        host.portForwards.append(
                                            PortForwardRule(kind: .dynamic, bindAddress: "127.0.0.1", listenPort: validPort, label: "SOCKS5 Proxy")
                                        )
                                    }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }

                    ForEach($host.portForwards) { $rule in
                        if rule.kind != .dynamic {
                            LabeledContent {
                                HStack(spacing: 8) {
                                    Text(rule.autoStart ? "Auto-start" : "Paused")
                                        .font(.caption)
                                        .foregroundStyle(rule.autoStart ? .secondary : .tertiary)
                                    Toggle("", isOn: $rule.autoStart)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                        .controlSize(.small)
                                        .help("Start automatically on connect")
                                    Button {
                                        host.portForwards.removeAll { $0.id == rule.id }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove redirect")
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(rule.kind.shortBadge)
                                        .font(.caption2.monospaced().weight(.semibold))
                                        .foregroundStyle(.teal)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(.teal.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                                    Text(rule.displaySummary)
                                        .font(.system(.callout, design: .monospaced))
                                        .lineLimit(1)
                                        .layoutPriority(1)
                                }
                            }
                        }
                    }

                    LabeledContent("Add port redirect") {
                        HStack(spacing: 6) {
                            Picker("", selection: $newForwardKind) {
                                Text("Local (-L)").tag(PortForwardKind.local)
                                Text("Remote (-R)").tag(PortForwardKind.remote)
                            }
                            .labelsHidden()
                            .frame(width: 105)

                            TextField("", text: $newLocalPort, prompt: Text("Mac port"))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                                .frame(width: 78)
                                .onChange(of: newLocalPort) { _, newValue in
                                    let cleaned = newValue.replacingOccurrences(of: ",", with: "")
                                    if cleaned != newValue { newLocalPort = cleaned }
                                }
                                .onSubmit { addDraftForward() }

                            Image(systemName: newForwardKind == .local ? "arrow.left" : "arrow.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            let trimmedLocal = newLocalPort.trimmingCharacters(in: .whitespaces)
                            let remotePrompt = trimmedLocal.isEmpty
                                ? (newForwardKind == .local ? "Port or IP:port" : "Server port")
                                : (newForwardKind == .local && Int(trimmedLocal) != nil ? "\(trimmedLocal) or IP:\(trimmedLocal)" : "Same port")
                            TextField("", text: $newRemotePort, prompt: Text(verbatim: remotePrompt))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                                .frame(minWidth: 120, maxWidth: .infinity)
                                .onChange(of: newRemotePort) { _, newValue in
                                    let cleaned = newValue.replacingOccurrences(of: ",", with: "")
                                    if cleaned != newValue { newRemotePort = cleaned }
                                }
                                .onSubmit { addDraftForward() }

                            Button("Add") { addDraftForward() }
                                .disabled(
                                    newLocalPort.trimmingCharacters(in: .whitespaces).isEmpty
                                        && newRemotePort.trimmingCharacters(in: .whitespaces).isEmpty
                                )
                        }
                    }
                    if let newForwardError {
                        Text(newForwardError).font(.caption).foregroundStyle(.orange)
                    }
                    Footnote("Press ⇧⌘L in any open SSH tab to toggle a SOCKS5 proxy or add port redirects on the fly.")
                }
                if !isNew {
                    Section("Shell integration on this host") {
                        RemoteIntegrationSection(host: host, services: services) { installed, marker in
                            host.remoteIntegration = installed
                            host.remoteIntegrationMarker = marker
                        }
                    }
                }
                Section("Organise") {
                    TextField("Tags", text: $tags, prompt: Text("prod, web"))
                    Picker("Colour", selection: $host.color) {
                        ForEach(HostColor.allCases, id: \.self) { color in
                            Label(color.rawValue.capitalized, systemImage: "circle.fill")
                                .foregroundStyle(color.color ?? .secondary)
                                .tag(color)
                        }
                    }
                    Picker("Theme", selection: $host.themeID) {
                        Text("Default").tag(String?.none)
                        ForEach(BuiltInThemes.all) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    Toggle("Favourite", isOn: $host.isFavorite)
                    TextField("Notes", text: .optionalString($host.notes), axis: .vertical).lineLimit(2...4)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let problem = problems.first {
                    Label(problem.localizedDescription, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                } else if testing {
                    ProgressView().controlSize(.small)
                } else if let reachability {
                    Label(reachability ? "Reachable" : "Not reachable", systemImage: reachability ? "checkmark.circle" : "xmark.octagon")
                        .foregroundStyle(reachability ? .green : .red).font(.callout)
                }
                Spacer()
                Button("Test") { test() }.disabled(!problems.isEmpty)
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Host" : "Save") {
                    commitAndSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!problems.isEmpty)
            }
            .padding()
        }
        .frame(width: 540, height: 700)
    }

    private var hasPendingDraftForward: Bool {
        !newLocalPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !newRemotePort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    private func addDraftForward() -> Bool {
        do {
            let rule = try PortForwardRule.build(
                kind: newForwardKind,
                localInput: newLocalPort,
                remoteInput: newRemotePort
            )
            host.portForwards.removeAll { $0.endpointKey == rule.endpointKey }
            host.portForwards.append(rule)
            newLocalPort = ""
            newRemotePort = ""
            newForwardError = nil
            return true
        } catch {
            newForwardError = error.localizedDescription
            return false
        }
    }

    private func commitAndSave() {
        if hasPendingDraftForward, !addDraftForward() {
            return
        }
        guard problems.isEmpty else { return }
        host.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if host.name.trimmingCharacters(in: .whitespaces).isEmpty { host.name = host.hostname }
        save(host)
    }

    private func test() {
        testing = true
        let target = host
        let builder = SSHCommandBuilder(settings: services.settings.settings.ssh, controlDirectory: services.paths.sshControl)
        Task {
            let resolveSpec = builder.resolveConfig(target)
            let resolvedResult = try? await ProcessRunner.run(resolveSpec.executable, resolveSpec.arguments, timeout: .seconds(5))
            let stdout = resolvedResult.map { String(decoding: $0.stdout, as: UTF8.self) } ?? ""
            let resolved = SSHCommandBuilder.parseEffectiveTarget(from: stdout, fallback: target)
            if resolved.hasProxyOrJump {
                let cmdSpec = builder.remoteCommand("true", on: target)
                if let probe = try? await ProcessRunner.run(cmdSpec.executable, cmdSpec.arguments, timeout: .seconds(10)) {
                    let stderr = String(decoding: probe.stderr, as: UTF8.self)
                    reachability = probe.succeeded || stderr.localizedCaseInsensitiveContains("Permission denied")
                } else {
                    reachability = false
                }
            } else {
                reachability = await FailureAdvisorProxy.probe(host: resolved.hostname, port: resolved.port)
            }
            testing = false
        }
    }
}

private struct SSHConfigImportView: View {
    let candidates: [SSHConfigEntry]
    let library: HostLibrary
    let done: () -> Void
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from ~/.ssh/config").font(.title3.weight(.semibold))
            if candidates.isEmpty {
                Text("There are no new hosts to import.").foregroundStyle(.secondary)
            } else {
                Text("Imported hosts keep using your config, so its options still apply.").foregroundStyle(.secondary)
                List(candidates, id: \.alias) { entry in
                    Toggle(isOn: Binding(
                        get: { selected.contains(entry.alias) },
                        set: { if $0 { selected.insert(entry.alias) } else { selected.remove(entry.alias) } })) {
                        VStack(alignment: .leading) {
                            Text(entry.alias)
                            Text(entry.resolvedDestination).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minHeight: 220)
            }
            HStack {
                Button("Select All") { selected = Set(candidates.map(\.alias)) }.disabled(candidates.isEmpty)
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Import \(selected.count) Host\(selected.count == 1 ? "" : "s")") {
                    library.importHosts(candidates.filter { selected.contains($0.alias) }.map { $0.makeHostProfile() })
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 420)
        .onAppear { selected = Set(candidates.map(\.alias)) }
    }
}
