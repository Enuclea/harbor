import Foundation
import HarborCore

/// Runs a command on a remote host and returns its output.
public typealias RemoteExecutor = @Sendable (_ command: String) async throws -> ProcessResult

extension SSHCommandBuilder {
    /// An executor that rides the host's shared connection and forwards `LC_TERMINAL=Harbor`
    /// exactly as a terminal tab would, so it observes the same environment.
    public func executor(for host: HostProfile, environment: [String: String] = ProcessInfo.processInfo.environment) -> RemoteExecutor {
        var env = environment
        env["LC_TERMINAL"] = AppIdentity.name
        let frozen = env
        return { command in
            let spec = remoteCommand(command, on: host)
            return try await ProcessRunner.run(spec.executable, spec.arguments, environment: frozen, timeout: .seconds(30))
        }
    }
}
