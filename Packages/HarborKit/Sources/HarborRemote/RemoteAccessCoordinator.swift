import Foundation
import HarborControl
import HarborCore
import HarborLogging
import Observation

public enum TunnelState: Sendable, Equatable {
    case stopped
    case starting
    case running(URL)
    case failed(String)
}

/// Turns the Remote Access settings into a running server and tunnel, and exposes their
/// state to the UI.
@MainActor
@Observable
public final class RemoteAccessCoordinator {
    public private(set) var localURL: URL?
    public private(set) var serverError: String?
    public private(set) var tunnelState: TunnelState = .stopped
    /// Recent tunnel client output, for the log disclosure in settings.
    public private(set) var tunnelLog: [String] = []

    @ObservationIgnored public let authenticator: RemoteAuthenticator
    @ObservationIgnored private let server: RemoteServer
    @ObservationIgnored private let allowlist = HostAllowlist()
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private var tunnel: RunningTunnel?
    @ObservationIgnored private var applied: RemoteAccessSettings?
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var pending: RemoteAccessSettings?
    @ObservationIgnored private let log = Log(.remote)

    public init(
        control: any TerminalControlling & TerminalStreaming,
        keychain: KeychainStore,
        audit: AuditTrail,
        currentSettings: @escaping @MainActor @Sendable () -> RemoteAccessSettings
    ) {
        self.keychain = keychain
        authenticator = RemoteAuthenticator(keychain: keychain, audit: audit)
        let allowlist = allowlist
        server = RemoteServer(control: control, authenticator: authenticator, allowlist: allowlist) {
            await MainActor.run { currentSettings() }
        }
    }

    /// The public address, once a tunnel is up.
    public var publicURL: URL? {
        if case .running(let url) = tunnelState { return url }
        return nil
    }

    /// A link that signs a browser in. The token travels in the URL *fragment*, which
    /// browsers never send to servers, so it doesn't reach tunnel providers' logs.
    public func pairingLink() async -> URL? {
        guard let base = publicURL ?? localURL, let token = try? await authenticator.currentToken() else { return nil }
        return URL(string: base.absoluteString + "/#token=" + token)
    }

    public func accessToken() async -> String? {
        try? await authenticator.currentToken()
    }

    public func rotateToken() async throws -> String {
        try await authenticator.rotateToken()
    }

    // MARK: Applying settings

    /// Brings the server and tunnel in line with `settings`. Safe to call on every change;
    /// overlapping calls are coalesced.
    public func apply(_ settings: RemoteAccessSettings) async {
        if applying {
            pending = settings
            return
        }
        applying = true
        defer { applying = false }
        var next: RemoteAccessSettings? = settings
        while let target = next {
            pending = nil
            await reconcile(target)
            next = pending
        }
    }

    private func reconcile(_ settings: RemoteAccessSettings) async {
        let previous = applied
        applied = settings
        await authenticator.setSessionLifetime(hours: settings.sessionLifetimeHours)

        guard settings.enabled else {
            await stopTunnel()
            await server.stop()
            localURL = nil
            serverError = nil
            return
        }

        let serverRunning = await server.isRunning
        if previous?.port != settings.port || !serverRunning {
            await stopTunnel()
            await server.stop()
            do {
                let port = try await server.start(port: settings.port)
                localURL = URL(string: "http://127.0.0.1:\(port)")
                serverError = nil
            } catch {
                serverError = error.localizedDescription
                localURL = nil
                return
            }
        }

        let tunnelChanged = previous?.tunnel != settings.tunnel || previous?.publicHostname != settings.publicHostname
        if tunnelChanged || tunnelState == .stopped || isFailed {
            await stopTunnel()
            if settings.tunnel != .none, let port = await server.port {
                await startTunnel(settings, port: port)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = tunnelState { return true }
        return false
    }

    private func startTunnel(_ settings: RemoteAccessSettings, port: Int) async {
        guard let provider = provider(for: settings) else { return }
        tunnelState = .starting
        tunnelLog = []
        do {
            let running = try await provider.start(localPort: port) { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            }
            tunnel = running
            allowlist.allow(running.publicURL.absoluteString)
            tunnelState = .running(running.publicURL)
            log.notice("tunnel \(settings.tunnel.rawValue) up at \(running.publicURL.absoluteString)")
        } catch {
            tunnelState = .failed(error.localizedDescription)
            log.warning("tunnel \(settings.tunnel.rawValue) failed: \(error.localizedDescription)")
        }
    }

    private func stopTunnel() async {
        if let tunnel {
            allowlist.remove(tunnel.publicURL.absoluteString)
            await tunnel.stop()
        }
        tunnel = nil
        tunnelState = .stopped
    }

    public func shutdown() async {
        await stopTunnel()
        await server.stop()
    }

    public func provider(for settings: RemoteAccessSettings) -> (any TunnelProvider)? {
        switch settings.tunnel {
        case .none: return nil
        case .cloudflareQuick: return CloudflareQuickTunnel()
        case .tailscaleServe: return TailscaleServeTunnel()
        case .cloudflareNamed:
            let token = (try? keychain.string(for: CloudflareNamedTunnel.tokenAccount)) ?? ""
            return CloudflareNamedTunnel(token: token, hostname: settings.publicHostname ?? "")
        }
    }

    private func appendLog(_ line: String) {
        tunnelLog.append(line)
        if tunnelLog.count > 200 { tunnelLog.removeFirst(tunnelLog.count - 200) }
    }
}
