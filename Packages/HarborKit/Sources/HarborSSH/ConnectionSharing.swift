import Foundation
import HarborCore

public enum PortForwardError: Error, LocalizedError, Equatable {
    case invalidRule
    case connectionSharingDisabled
    case masterNotConnected
    case sshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRule:
            "The port forward or proxy has an invalid port or address."
        case .connectionSharingDisabled:
            "Enable “Share one sign-in per host” in Settings ▸ SSH to add live redirects and proxies."
        case .masterNotConnected:
            "Wait until the SSH tab finishes signing in before adding a live redirect or proxy."
        case .sshFailed(let message):
            message.isEmpty ? "OpenSSH refused the port forward." : message
        }
    }
}

/// Queries, forwards ports on, and closes shared (ControlMaster) connections.
public struct ConnectionSharing: Sendable {
    public let builder: SSHCommandBuilder

    public init(builder: SSHCommandBuilder) {
        self.builder = builder
    }

    /// True when an authenticated master connection to `host` is up.
    public func isConnected(_ host: HostProfile) async -> Bool {
        guard builder.connectionSharing else { return false }
        let command = builder.controlCheck(host)
        let result = try? await ProcessRunner.run(command.executable, command.arguments, timeout: .seconds(5))
        return result?.succeeded ?? false
    }

    /// Starts a live port forward (`-L`, `-R`) or dynamic SOCKS5 proxy (`-D`) on `host`'s shared connection.
    public func startForward(_ rule: PortForwardRule, on host: HostProfile) async throws {
        guard HostProfileValidator.isValidForward(rule) else {
            throw PortForwardError.invalidRule
        }
        guard builder.connectionSharing else {
            throw PortForwardError.connectionSharingDisabled
        }
        let command = builder.controlForward(rule, on: host)
        let result = try await ProcessRunner.run(command.executable, command.arguments, timeout: .seconds(8))
        guard result.succeeded else {
            let stderr = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if stderr.localizedCaseInsensitiveContains("Control socket connect") || stderr.localizedCaseInsensitiveContains("No such file") {
                throw PortForwardError.masterNotConnected
            }
            throw PortForwardError.sshFailed(stderr)
        }
    }

    /// Stops a live port forward (`-L`, `-R`) or dynamic SOCKS5 proxy (`-D`) on `host`'s shared connection.
    public func stopForward(_ rule: PortForwardRule, on host: HostProfile) async throws {
        guard HostProfileValidator.isValidForward(rule) else {
            throw PortForwardError.invalidRule
        }
        guard builder.connectionSharing else {
            throw PortForwardError.connectionSharingDisabled
        }
        let command = builder.controlCancel(rule, on: host)
        let result = try await ProcessRunner.run(command.executable, command.arguments, timeout: .seconds(8))
        guard result.succeeded else {
            let stderr = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PortForwardError.sshFailed(stderr)
        }
    }

    /// Ends the shared connection, e.g. when the user explicitly disconnects a host.
    public func disconnect(_ host: HostProfile) async {
        let command = builder.controlExit(host)
        _ = try? await ProcessRunner.run(command.executable, command.arguments, timeout: .seconds(5))
    }
}
