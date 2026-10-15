import Foundation
import HarborCore

/// Queries and closes shared (ControlMaster) connections.
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

    /// Ends the shared connection, e.g. when the user explicitly disconnects a host.
    public func disconnect(_ host: HostProfile) async {
        let command = builder.controlExit(host)
        _ = try? await ProcessRunner.run(command.executable, command.arguments, timeout: .seconds(5))
    }
}
