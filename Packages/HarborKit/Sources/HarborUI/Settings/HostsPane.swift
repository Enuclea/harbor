import HarborCore
import HarborSSH
import SwiftUI

struct HostsPane: View {
    let library: HostLibrary
    let services: AppServices
    @State private var query = ""
    @State private var editing: HostProfile?
    @State private var importCandidates: [SSHConfigEntry]?
    @State private var selection: HostID?

    var body: some View {
        VStack(spacing: 0) {
            if library.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No Hosts Yet", systemImage: "server.rack")
                } description: {
                    Text("Save the machines you connect to and open them in one click — from here, Quick Connect (⇧⌘K), the Dock menu, or an AI assistant.")
                } actions: {
                    Button("Add Host…") { editing = HostProfile(name: "", hostname: "") }
                        .buttonStyle(.borderedProminent)
                    Button("Import from ~/.ssh/config…") { loadImportCandidates() }
                }
            } else {
                List(selection: $selection) {
                    ForEach(library.search(query)) { host in
                        HostRow(host: host)
                            .tag(host.id)
                            .contextMenu { menu(for: host) }
                    }
                }
                .contextMenu(forSelectionType: HostID.self) { _ in } primaryAction: { ids in
                    if let id = ids.first, let host = library.host(id: id) { services.actions?.connect(to: host) }
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Filter hosts")
        .toolbar {
            ToolbarItemGroup {
                Button { loadImportCandidates() } label: { Label("Import from SSH config", systemImage: "square.and.arrow.down") }
                    .help("Import hosts from ~/.ssh/config")
                Button { editing = HostProfile(name: "", hostname: "") } label: { Label("Add Host", systemImage: "plus") }
                    .help("Add a host")
            }
        }
        .sheet(item: $editing) { host in
            HostEditorView(host: host, isNew: library.host(id: host.id) == nil, services: services) { saved in
                library.upsert(saved)
                editing = nil
            } cancel: {
                editing = nil
            }
        }
        .sheet(isPresented: Binding(get: { importCandidates != nil }, set: { if !$0 { importCandidates = nil } })) {
            SSHConfigImportView(candidates: importCandidates ?? [], library: library) { importCandidates = nil }
        }
    }

    @ViewBuilder
    private func menu(for host: HostProfile) -> some View {
        Button("Connect") { services.actions?.connect(to: host) }
        Button("Edit…") { editing = host }
        Button("Duplicate") {
            var copy = host
            copy.id = HostID()
            copy.name += " copy"
            library.upsert(copy)
        }
        Button(host.isFavorite ? "Remove from Favourites" : "Add to Favourites") {
            var updated = host
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
            ForEach(host.tags.prefix(3), id: \.self) { tag in
                Text(tag).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            if let last = host.lastConnected {
                Text(last, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary)
            }
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
    @State private var reachability: Bool?
    @State private var testing = false

    init(host: HostProfile, isNew: Bool, services: AppServices, save: @escaping (HostProfile) -> Void, cancel: @escaping () -> Void) {
        _host = State(initialValue: host)
        _tags = State(initialValue: host.tags.joined(separator: ", "))
        self.isNew = isNew
        self.services = services
        self.save = save
        self.cancel = cancel
    }

    private var problems: [HostProfileProblem] { HostProfileValidator.problems(in: host) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Connection") {
                    TextField("Name", text: $host.name, prompt: Text(host.hostname.isEmpty ? "Production API" : host.hostname))
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
                Button("Test") { test() }.disabled(!problems.isEmpty || host.usesSSHConfigAlias)
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Host" : "Save") {
                    host.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if host.name.trimmingCharacters(in: .whitespaces).isEmpty { host.name = host.hostname }
                    save(host)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!problems.isEmpty)
            }
            .padding()
        }
        .frame(width: 540, height: 700)
    }

    private func test() {
        testing = true
        let target = host
        Task {
            reachability = await FailureAdvisorProxy.probe(host: target.hostname, port: target.port ?? 22)
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
