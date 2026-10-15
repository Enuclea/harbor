import Foundation
import HarborCore
import HarborLogging

public enum TunnelError: Error, LocalizedError, Equatable {
    case notInstalled(tool: String, install: String)
    case missingConfiguration(String)
    case failedToConnect(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let tool, let install): "\(tool) isn't installed. Install it with: \(install)"
        case .missingConfiguration(let detail): detail
        case .failedToConnect(let detail): detail
        }
    }
}

/// A tunnel that is up, and how to take it down.
public struct RunningTunnel: Sendable {
    public let publicURL: URL
    let stop: @Sendable () async -> Void
}

/// Publishes the loopback-only remote server to the outside world.
public protocol TunnelProvider: Sendable {
    var kind: TunnelKind { get }
    /// The command-line tool this provider needs, e.g. `cloudflared`.
    var toolName: String { get }
    var installCommand: String { get }
    func start(localPort: Int, onLine: @escaping @Sendable (String) -> Void) async throws -> RunningTunnel
}

extension TunnelProvider {
    public var toolPath: String? { ExecutableLocator.find(toolName) }
    public var isInstalled: Bool { toolPath != nil }

    func requireTool() throws -> String {
        guard let path = toolPath else { throw TunnelError.notInstalled(tool: toolName, install: installCommand) }
        return path
    }
}

/// `cloudflared tunnel --url …`: an instant, random `*.trycloudflare.com` address. No
/// account needed, but the URL changes every time — best for occasional use.
public struct CloudflareQuickTunnel: TunnelProvider {
    public let kind = TunnelKind.cloudflareQuick
    public let toolName = "cloudflared"
    public let installCommand = "brew install cloudflared"

    public init() {}

    public func start(localPort: Int, onLine: @escaping @Sendable (String) -> Void) async throws -> RunningTunnel {
        let process = try TunnelProcess(
            executable: try requireTool(),
            arguments: ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(localPort)"],
            environment: ProcessInfo.processInfo.environment, onLine: onLine)
        guard let address = await process.firstMatch(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, timeout: .seconds(45)),
              let url = URL(string: address) else {
            process.terminate()
            throw TunnelError.failedToConnect("cloudflared didn't report a tunnel address. Check the tunnel log for details.")
        }
        return RunningTunnel(publicURL: url) { process.terminate() }
    }
}

/// A named Cloudflare tunnel created in the Zero Trust dashboard, run with its token.
/// The stable hostname and its Access policy live in Cloudflare, so identity is checked
/// before traffic reaches the Mac. The token is passed via environment, never argv.
public struct CloudflareNamedTunnel: TunnelProvider {
    public static let tokenAccount = "cloudflare-tunnel-token"

    public let kind = TunnelKind.cloudflareNamed
    public let toolName = "cloudflared"
    public let installCommand = "brew install cloudflared"
    let token: String
    let hostname: String

    public init(token: String, hostname: String) {
        self.token = token
        self.hostname = hostname
    }

    public func start(localPort: Int, onLine: @escaping @Sendable (String) -> Void) async throws -> RunningTunnel {
        guard !token.isEmpty else { throw TunnelError.missingConfiguration("Add your Cloudflare tunnel token in Remote Access settings.") }
        let host = hostname.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !host.isEmpty, let url = URL(string: "https://\(host)") else {
            throw TunnelError.missingConfiguration("Enter the public hostname you routed to this tunnel in Cloudflare.")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["TUNNEL_TOKEN"] = token
        let process = try TunnelProcess(
            executable: try requireTool(), arguments: ["tunnel", "--no-autoupdate", "run"],
            environment: environment, onLine: onLine)
        guard await process.firstMatch(of: "Registered tunnel connection", timeout: .seconds(45)) != nil else {
            process.terminate()
            throw TunnelError.failedToConnect("cloudflared couldn't connect with that token. Check the tunnel log for details.")
        }
        return RunningTunnel(publicURL: url) { process.terminate() }
    }
}

/// `tailscale serve`: HTTPS on the Mac's tailnet name, reachable only by the user's own
/// devices. The most private option; requires Tailscale on each device.
public struct TailscaleServeTunnel: TunnelProvider {
    public let kind = TunnelKind.tailscaleServe
    public let toolName = "tailscale"
    public let installCommand = "brew install --cask tailscale"

    public init() {}

    public func start(localPort: Int, onLine: @escaping @Sendable (String) -> Void) async throws -> RunningTunnel {
        let tool = try requireTool()
        let serve = try await ProcessRunner.run(tool, ["serve", "--bg", "--https=443", "http://127.0.0.1:\(localPort)"], timeout: .seconds(30))
        (serve.output + serve.errorOutput).split(separator: "\n").map(String.init).forEach(onLine)
        guard serve.succeeded else {
            throw TunnelError.failedToConnect((serve.errorOutput + serve.output).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let status = try await ProcessRunner.run(tool, ["status", "--json"], timeout: .seconds(10))
        guard let object = try? JSONSerialization.jsonObject(with: status.stdout) as? [String: Any],
              let me = object["Self"] as? [String: Any],
              let dnsName = (me["DNSName"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !dnsName.isEmpty, let url = URL(string: "https://\(dnsName)") else {
            throw TunnelError.failedToConnect("Tailscale is serving, but its hostname couldn't be read. Is Tailscale signed in?")
        }
        return RunningTunnel(publicURL: url) {
            _ = try? await ProcessRunner.run(tool, ["serve", "--https=443", "off"], timeout: .seconds(15))
        }
    }
}
