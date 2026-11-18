import AppKit
import HarborCore
import HarborSessions
import HarborSSH
import Observation
import SwiftUI

/// Coordinates on-the-fly SSH port forwards (`-L` / `-R`) and dynamic SOCKS5 proxies (`-D`)
/// for a terminal tab (`⇧⌘L` or right-click tab ▸ Quick Redirect / Proxy…).
@MainActor
@Observable
final class PortForwardModel {
    var isVisible = false
    /// Direction for port redirects (`.local` `-L` or `.remote` `-R`).
    var redirectKind: PortForwardKind = .local
    var localPortInput = ""
    var remotePortInput = ""
    var targetHostInput = ""
    var showTargetHostField = false
    var socksPortInput = "1080"
    var isWorking = false
    var errorMessage: String?
    var statusNotice: String?

    @ObservationIgnored private let session: TerminalSession
    @ObservationIgnored let services: AppServices
    @ObservationIgnored var onDismiss: @MainActor () -> Void = {}

    init(session: TerminalSession, services: AppServices) {
        self.session = session
        self.services = services
    }

    var isSSHSession: Bool {
        session.kind.host != nil
    }

    var effectiveHost: HostProfile? {
        guard let original = session.kind.host else { return nil }
        return services.hosts.host(id: original.id) ?? original
    }

    var activeForwards: [PortForwardRule] {
        session.activePortForwards
    }

    /// Active SOCKS5 (`-D`) rule on this session, if any.
    var activeSocksRule: PortForwardRule? {
        activeForwards.first { $0.kind == .dynamic }
    }

    /// Active port redirects (`-L` / `-R`), excluding SOCKS5 which has its own toggle row.
    var activeRedirects: [PortForwardRule] {
        activeForwards.filter { $0.kind != .dynamic }
    }

    var savedInactiveForwards: [PortForwardRule] {
        guard let host = effectiveHost else { return [] }
        let activeKeys = Set(activeForwards.map(\.endpointKey))
        return host.portForwards.filter { !activeKeys.contains($0.endpointKey) }
    }

    var canSubmitRedirect: Bool {
        guard !isWorking else { return false }
        let hasLocal = !localPortInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasRemote = !remotePortInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasTarget = !targetHostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasLocal || hasRemote || hasTarget
    }

    func toggle() {
        isVisible.toggle()
        if isVisible {
            if let socks = activeSocksRule {
                socksPortInput = String(socks.listenPort)
            }
        } else {
            errorMessage = nil
            statusNotice = nil
            onDismiss()
        }
    }

    /// Toggles the SOCKS5 dynamic proxy (`-D`) on or off with one click.
    func setSocksEnabled(_ enabled: Bool) async {
        guard !isWorking else { return }
        if !enabled {
            if let existing = activeSocksRule {
                await stopForward(existing)
            }
            return
        }
        let portText = socksPortInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePortText = portText.isEmpty ? "1080" : portText
        do {
            let rule = try PortForwardRule.parse(effectivePortText, defaultKind: .dynamic, label: "SOCKS5 Proxy")
            socksPortInput = String(rule.listenPort)
            await startForward(rule)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Submits the structured `This Mac` ⇄ `Remote` fields, supporting ports, `IP:port` / `host:port` combos, or shorthand specs.
    func submitRedirect() async {
        guard canSubmitRedirect else { return }

        errorMessage = nil
        statusNotice = nil

        do {
            let rule = try PortForwardRule.build(
                kind: redirectKind,
                localInput: localPortInput,
                remoteInput: remotePortInput,
                targetHostInput: targetHostInput
            )
            await startForward(rule)
            if errorMessage == nil {
                localPortInput = ""
                remotePortInput = ""
                targetHostInput = ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Toggles a common local port preset (`3000`, `5173`, `8080`, `5432`, `6379`) in one click.
    func togglePresetPort(_ port: Int, label: String) async {
        guard !isWorking else { return }
        if let existing = activeRedirects.first(where: { $0.kind == .local && $0.listenPort == port }) {
            await stopForward(existing)
        } else {
            let rule = PortForwardRule(
                kind: .local,
                bindAddress: "127.0.0.1",
                listenPort: port,
                targetHost: "127.0.0.1",
                targetPort: port,
                label: label
            )
            await startForward(rule)
        }
    }

    func isPresetPortActive(_ port: Int) -> Bool {
        activeRedirects.contains { $0.kind == .local && $0.listenPort == port }
    }

    func startForward(_ rule: PortForwardRule) async {
        guard let host = effectiveHost else {
            errorMessage = "Open an SSH tab first to start redirects or a proxy."
            return
        }
        guard session.state.isRunning else {
            errorMessage = "This SSH tab is disconnected. Reconnect first."
            return
        }
        isWorking = true
        errorMessage = nil
        statusNotice = nil
        let builder = SSHCommandBuilder(
            settings: services.settings.settings.ssh,
            controlDirectory: services.paths.sshControl
        )
        let sharing = ConnectionSharing(builder: builder)
        do {
            try await sharing.startForward(rule, on: host)
            session.recordActiveForward(rule)
            statusNotice = "Active: \(rule.displaySummary)"
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    func stopForward(_ rule: PortForwardRule) async {
        guard let host = effectiveHost else {
            session.removeActiveForward(id: rule.id)
            return
        }
        isWorking = true
        errorMessage = nil
        statusNotice = nil
        let builder = SSHCommandBuilder(
            settings: services.settings.settings.ssh,
            controlDirectory: services.paths.sshControl
        )
        let sharing = ConnectionSharing(builder: builder)
        do {
            try await sharing.stopForward(rule, on: host)
            session.removeActiveForward(id: rule.id)
            statusNotice = "Stopped \(rule.displaySummary)"
        } catch {
            session.removeActiveForward(id: rule.id)
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    func isSavedOnHost(_ rule: PortForwardRule) -> Bool {
        guard let host = effectiveHost else { return false }
        return host.portForwards.contains { $0.endpointKey == rule.endpointKey }
    }

    func toggleSavedOnHost(_ rule: PortForwardRule) {
        guard var host = effectiveHost else { return }
        if let index = host.portForwards.firstIndex(where: { $0.endpointKey == rule.endpointKey }) {
            host.portForwards.remove(at: index)
            statusNotice = "Unpinned \(rule.displaySummary) from \(host.name)"
        } else {
            host.portForwards.append(rule)
            statusNotice = "Pinned \(rule.displaySummary) to \(host.name) (auto-starts on connect)"
        }
        services.hosts.upsert(host)
    }

    func connectHost(_ host: HostProfile) {
        isVisible = false
        onDismiss()
        services.actions?.connect(to: host)
    }
}

/// Compact floating popover panel (`⇧⌘L`) for toggling a SOCKS5 proxy (`-D`) or forwarding ports (`-L` / `-R`).
struct PortForwardBar: View {
    @Bindable var model: PortForwardModel
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case localPort
        case remotePort
        case targetHost
        case socksPort
    }

    static let panelWidth: CGFloat = 445

    var body: some View {
        if model.isVisible {
            VStack(alignment: .leading, spacing: 10) {
                headerRow
                if model.isSSHSession {
                    socksProxyCard
                    portRedirectCard
                    statusBanner
                    activeRedirectsSection
                    savedInactiveSection
                } else {
                    localTabCard
                }
            }
            .padding(12)
            .frame(width: Self.panelWidth)
            .glassPanel(cornerRadius: 13)
            .onAppear {
                focusedField = .localPort
            }
            .onKeyPress(.escape) {
                model.isVisible = false
                model.onDismiss()
                return .handled
            }
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .foregroundStyle(.teal)
                .font(.callout.weight(.semibold))
            Text("Redirects & Proxy")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if let host = model.effectiveHost {
                Text("· \(host.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if !model.activeForwards.isEmpty {
                Text(verbatim: "\(model.activeForwards.count) active")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.teal)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.teal.opacity(0.15), in: Capsule())
            }
            Button {
                model.isVisible = false
                model.onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
        }
    }

    // MARK: 1-Click SOCKS5 Proxy Card

    private var socksProxyCard: some View {
        let activeSocks = model.activeSocksRule
        let isOn = activeSocks != nil

        return HStack(spacing: 8) {
            Image(systemName: isOn ? "network.badge.shield.half.filled" : "network")
                .foregroundStyle(isOn ? .green : .secondary)
                .font(.callout)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("SOCKS5 Proxy")
                        .font(.caption.weight(.semibold))
                    if let activeSocks {
                        Text(verbatim: "localhost:\(activeSocks.listenPort)")
                            .font(.caption.monospaced().weight(.medium))
                            .foregroundStyle(.green)
                    } else {
                        HStack(spacing: 2) {
                            Text("localhost:")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            TextField("", text: $model.socksPortInput, prompt: Text("1080"))
                                .textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced())
                                .frame(width: 58)
                                .focused($focusedField, equals: .socksPort)
                                .onChange(of: model.socksPortInput) { _, newValue in
                                    let cleaned = newValue.replacingOccurrences(of: ",", with: "")
                                    if cleaned != newValue { model.socksPortInput = cleaned }
                                }
                                .onSubmit {
                                    Task { await model.setSocksEnabled(true) }
                                }
                        }
                    }
                }
                Text(isOn ? "Routing SOCKS5 traffic through this SSH host" : "Route browser or CLI traffic through this SSH host (-D)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let activeSocks {
                Button {
                    let snippet = "export \(activeSocks.copyableSnippet)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    model.statusNotice = "Copied \(snippet)"
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copy export \(activeSocks.copyableSnippet)")

                let saved = model.isSavedOnHost(activeSocks)
                Button {
                    model.toggleSavedOnHost(activeSocks)
                } label: {
                    Image(systemName: saved ? "pin.fill" : "pin")
                        .foregroundStyle(saved ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(saved ? "Pinned to auto-start on connect" : "Pin to auto-start on connect")
            }

            Toggle("", isOn: Binding(
                get: { isOn },
                set: { newValue in Task { await model.setSocksEnabled(newValue) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(model.isWorking)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: Port Redirect Builder (-L / -R)

    private var portRedirectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Port Redirect")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.redirectKind = (model.redirectKind == .local) ? .remote : .local
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.redirectKind == .local ? "arrow.right" : "arrow.left")
                            .font(.caption2.weight(.bold))
                        Text(model.redirectKind == .local
                            ? "Server → This Mac (-L)"
                            : "This Mac → Server (-R)")
                            .font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.7), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Click to switch direction between Local (-L) and Remote (-R)")
            }

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.redirectKind == .local ? "This Mac Port" : "This Mac (Port or IP:Port)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    let localPrompt = model.remotePortInput.trimmingCharacters(in: .whitespaces).isEmpty
                        ? "e.g. 8080"
                        : "Same port"
                    TextField("", text: $model.localPortInput, prompt: Text(localPrompt))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .focused($focusedField, equals: .localPort)
                        .onChange(of: model.localPortInput) { _, newValue in
                            let cleaned = newValue.replacingOccurrences(of: ",", with: "")
                            if cleaned != newValue { model.localPortInput = cleaned }
                        }
                        .onSubmit {
                            Task { await model.submitRedirect() }
                        }
                }
                .frame(width: model.redirectKind == .local ? 112 : nil)

                Image(systemName: model.redirectKind == .local ? "arrow.left" : "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)
                    .padding(.top, 14)
                    .help(model.redirectKind == .local
                        ? "Connections to This Mac Port are forwarded through SSH to the Remote Port or IP:Port (-L)"
                        : "Connections to Server Port are forwarded back to This Mac (-R)")

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.redirectKind == .local ? "Remote (Port or IP:Port)" : "Server Port")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("", text: $model.remotePortInput, prompt: Text(verbatim: remoteFieldPrompt))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .focused($focusedField, equals: .remotePort)
                        .onChange(of: model.remotePortInput) { _, newValue in
                            let cleaned = newValue.replacingOccurrences(of: ",", with: "")
                            if cleaned != newValue { model.remotePortInput = cleaned }
                        }
                        .onSubmit {
                            Task { await model.submitRedirect() }
                        }
                }
                .frame(width: model.redirectKind == .remote ? 112 : nil)

                VStack(alignment: .leading, spacing: 2) {
                    Text(" ")
                        .font(.system(size: 10))
                    if model.isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 58, height: 22)
                    } else {
                        Button("Add") {
                            Task { await model.submitRedirect() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(!model.canSubmitRedirect)
                    }
                }
            }

            if model.showTargetHostField {
                HStack(spacing: 6) {
                    Text("Target host:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("", text: $model.targetHostInput, prompt: Text("127.0.0.1 or internal IP/host (e.g. 10.0.0.1)"))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .focused($focusedField, equals: .targetHost)
                        .onSubmit {
                            Task { await model.submitRedirect() }
                        }
                }
            }

            // 1-click common port toggles + target host toggle
            HStack(spacing: 5) {
                Text("Quick:")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                presetChip(port: 3000, label: "Dev 3000")
                presetChip(port: 5173, label: "Vite 5173")
                presetChip(port: 8080, label: "Web 8080")
                presetChip(port: 5432, label: "Postgres")
                presetChip(port: 6379, label: "Redis")
                Spacer(minLength: 2)
                Button {
                    model.showTargetHostField.toggle()
                } label: {
                    Text(model.showTargetHostField ? "Hide host" : "Target host…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
    }

    private var remoteFieldPrompt: String {
        let trimmedLocal = model.localPortInput.trimmingCharacters(in: .whitespaces)
        if model.redirectKind == .remote {
            return trimmedLocal.isEmpty ? "e.g. 9000" : "Same port"
        }
        if trimmedLocal.isEmpty {
            return "8080 or 10.0.0.1:8291"
        }
        if Int(trimmedLocal) != nil {
            return "\(trimmedLocal) or 10.0.0.1:\(trimmedLocal)"
        }
        return "Optional"
    }

    private func presetChip(port: Int, label: String) -> some View {
        let active = model.isPresetPortActive(port)
        let portString = String(port)
        return Button {
            Task { await model.togglePresetPort(port, label: label) }
        } label: {
            HStack(spacing: 3) {
                if active {
                    Circle().fill(.green).frame(width: 5, height: 5)
                }
                Text(verbatim: ":\(portString)")
                    .font(.caption2.monospaced().weight(active ? .semibold : .regular))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(active ? Color.teal.opacity(0.22) : Color.secondary.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.isWorking)
        .help(active ? "Stop forwarding port \(portString)" : "Forward localhost:\(portString) → remote:\(portString) (\(label))")
    }

    // MARK: Status Banner

    @ViewBuilder
    private var statusBanner: some View {
        if let error = model.errorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        } else if let notice = model.statusNotice {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Active & Pinned Lists

    @ViewBuilder
    private var activeRedirectsSection: some View {
        let redirects = model.activeRedirects
        if !redirects.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Active Port Redirects")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(redirects) { rule in
                    activeRedirectRow(rule)
                }
            }
        }
    }

    private func activeRedirectRow(_ rule: PortForwardRule) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
            Text(rule.kind.shortBadge)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(rule.displaySummary)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)

            if let url = rule.localBrowserURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Open \(url.absoluteString) in browser")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rule.copyableSnippet, forType: .string)
                model.statusNotice = "Copied \(rule.copyableSnippet)"
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Copy \(rule.copyableSnippet)")

            let saved = model.isSavedOnHost(rule)
            Button {
                model.toggleSavedOnHost(rule)
            } label: {
                Image(systemName: saved ? "pin.fill" : "pin")
                    .foregroundStyle(saved ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(saved ? "Pinned to auto-start on connect (click to unpin)" : "Pin to host so it starts automatically on connect")

            Button {
                Task { await model.stopForward(rule) }
            } label: {
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(model.isWorking)
            .help("Stop redirect")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private var savedInactiveSection: some View {
        let inactive = model.savedInactiveForwards
        if !inactive.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Pinned on Host (Stopped)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(inactive) { rule in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                        Text(rule.kind.shortBadge)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        Text(rule.displaySummary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button("Start") {
                            Task { await model.startForward(rule) }
                        }
                        .controlSize(.mini)
                        .disabled(model.isWorking)
                        Button {
                            model.toggleSavedOnHost(rule)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Remove from host")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: Local Shell Tab Fallback

    private var localTabCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Port redirects and SOCKS5 proxies tunnel over an active SSH tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let hosts = model.services.hosts.hosts
            if hosts.isEmpty {
                Button("Add an SSH Host…") {
                    model.isVisible = false
                    model.onDismiss()
                    model.services.actions?.openSettings(section: .hosts)
                }
                .controlSize(.small)
            } else {
                Text("Open an SSH host tab to start tunneling:")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                FlowHostChips(hosts: Array(hosts.prefix(6))) { host in
                    model.connectHost(host)
                }
            }
        }
    }
}

private struct FlowHostChips: View {
    let hosts: [HostProfile]
    let onSelect: (HostProfile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(hosts) { host in
                Button {
                    onSelect(host)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "server.rack")
                            .font(.caption)
                            .foregroundStyle(.teal)
                        Text(host.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(host.destinationLabel)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
