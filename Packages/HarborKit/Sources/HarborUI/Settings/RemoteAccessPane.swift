import CoreImage.CIFilterBuiltins
import HarborCore
import HarborRemote
import SwiftUI

struct RemoteAccessPane: View {
    @Bindable var store: SettingsStore
    let coordinator: RemoteAccessCoordinator
    let services: AppServices
    @State private var token = ""
    @State private var revealToken = false
    @State private var pairingLink: URL?
    @State private var tunnelToken = ""
    @State private var browsers: [RemoteSession] = []
    @State private var showLog = false

    var body: some View {
        Form {
            Section {
                Toggle("Allow access from a web browser", isOn: $store.settings.remote.enabled)
                Footnote("Use your terminals and hosts from any browser. Harbor listens on this Mac only; a tunnel makes it reachable, and every browser must sign in with your access token.")
            }

            if store.settings.remote.enabled {
                serverSection
                tunnelSection
                accessSection
                permissionsSection
            }
        }
        .formStyle(.grouped)
        .task(id: store.settings.remote.enabled) { await refresh() }
        .onChange(of: coordinator.tunnelState) { Task { await refresh() } }
    }

    private var serverSection: some View {
        Section("Server") {
            TextField("Port", value: $store.settings.remote.port, format: .number.grouping(.never))
            LabeledContent("On this Mac") {
                if let url = coordinator.localURL {
                    HStack {
                        Link(url.absoluteString, destination: url)
                        CopyButton(value: url.absoluteString)
                    }
                } else if let error = coordinator.serverError {
                    Text(error).foregroundStyle(.red)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private var tunnelSection: some View {
        Section("Reach it from elsewhere") {
            Picker("Publish with", selection: $store.settings.remote.tunnel) {
                ForEach(TunnelKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Footnote(tunnelExplanation)

            if store.settings.remote.tunnel == .cloudflareNamed {
                SecureField("Tunnel token", text: $tunnelToken, prompt: Text("From Zero Trust ▸ Networks ▸ Tunnels"))
                    .onSubmit(saveTunnelToken)
                TextField("Public hostname", text: .optionalString($store.settings.remote.publicHostname), prompt: Text("term.example.com"))
                Button("Save Token") { saveTunnelToken() }.disabled(tunnelToken.isEmpty)
            }

            if let provider = coordinator.provider(for: store.settings.remote), !provider.isInstalled {
                LabeledContent("\(provider.toolName) isn't installed") {
                    Button("Install…") {
                        services.actions?.runInNewTab(CommandSpecFactory.shell(provider.installCommand), title: "Install \(provider.toolName)")
                    }
                }
            }

            if store.settings.remote.tunnel != .none {
                LabeledContent("Status") { tunnelStatus }
                DisclosureGroup("Tunnel log", isExpanded: $showLog) {
                    ScrollView {
                        Text(coordinator.tunnelLog.suffix(80).joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 140)
                }
            }
        }
    }

    @ViewBuilder
    private var tunnelStatus: some View {
        switch coordinator.tunnelState {
        case .stopped: StatusBadge(text: "Stopped", tone: .neutral)
        case .starting: HStack { ProgressView().controlSize(.small); Text("Connecting…") }
        case .running(let url):
            HStack {
                Link(url.absoluteString, destination: url)
                CopyButton(value: url.absoluteString)
            }
        case .failed(let message): Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessSection: some View {
        Section("Sign-in") {
            LabeledContent("Access token") {
                HStack {
                    CodeText(revealToken ? token : String(repeating: "•", count: 24))
                    Button(revealToken ? "Hide" : "Show") { revealToken.toggle() }
                    CopyButton(value: token)
                }
            }
            if let pairingLink {
                HStack(alignment: .top, spacing: 16) {
                    QRCodeView(text: pairingLink.absoluteString).frame(width: 128, height: 128)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pairing link").font(.headline)
                        Text("Scan or open this link on your phone or another computer to sign in. Treat it like a password.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        CopyButton(value: pairingLink.absoluteString, label: "Copy Link")
                    }
                }
            }
            Button("New Token (Signs Out Every Browser)", role: .destructive) {
                Task {
                    token = (try? await coordinator.rotateToken()) ?? token
                    await refresh()
                }
            }
            if !browsers.isEmpty {
                ForEach(browsers, id: \.id) { browser in
                    LabeledContent(browser.clientAddress) {
                        Text("since \(browser.createdAt.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                    }
                }
                Button("Sign Out All Browsers") {
                    Task {
                        await coordinator.authenticator.signOutEveryone()
                        await refresh()
                    }
                }
            }
        }
    }

    private var permissionsSection: some View {
        Section("Browsers may") {
            Toggle("Type into tabs", isOn: $store.settings.remote.allowInput)
            Toggle("Open tabs and connect to hosts", isOn: $store.settings.remote.allowOpeningSessions)
            Stepper(value: $store.settings.remote.sessionLifetimeHours, in: 1...168) {
                LabeledContent("Stay signed in for", value: "\(store.settings.remote.sessionLifetimeHours) h")
            }
        }
    }

    private var tunnelExplanation: String {
        switch store.settings.remote.tunnel {
        case .none: "Only reachable from this Mac."
        case .tailscaleServe: "Most private: reachable only from devices signed in to your tailnet, over HTTPS. Recommended for everyday use."
        case .cloudflareNamed: "A stable hostname on your Cloudflare account. Put a Cloudflare Access policy in front of it so you sign in with your identity provider before reaching Harbor."
        case .cloudflareQuick: "An instant public trycloudflare.com address that changes every time. Protected only by your token — best for occasional use."
        }
    }

    private func saveTunnelToken() {
        guard !tunnelToken.isEmpty else { return }
        try? services.keychain.set(tunnelToken, for: CloudflareNamedTunnel.tokenAccount)
        tunnelToken = ""
        Task { await coordinator.apply(store.settings.remote) }
    }

    private func refresh() async {
        token = await coordinator.accessToken() ?? ""
        pairingLink = await coordinator.pairingLink()
        browsers = await coordinator.authenticator.activeSessions
    }
}

/// Renders text as a QR code, for pairing a phone.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                .padding(6)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
