import Foundation
import HarborDoctor
import HarborMCP
import HarborSSH

extension AppServices {
    /// Gathers the runtime facts diagnostics need.
    func actionsDoctorContext() async -> DoctorContext {
        let registered = await mcpRegistry.status().filter { $0.isRegistered && !$0.isStale }.map(\.app.displayName)
        let shells = Set(sessions.sessions.filter { $0.kind == .localShell }.compactMap(\.shellIntegration))
        let sshTabs: [SSHTabFact] = sessions.sessions.compactMap { session in
            guard let host = session.kind.host, session.state.isRunning else { return nil }
            let saved = hosts.host(id: host.id) ?? host
            return SSHTabFact(hostName: saved.name, integrationInstalled: saved.remoteIntegration,
                              reporting: session.shellIntegration != nil,
                              connectedSeconds: Date().timeIntervalSince(session.createdAt))
        }
        return DoctorContext(
            paths: paths, settings: settings.settings, appBundlePath: Bundle.main.bundlePath,
            bridgePath: Self.bridgePath, controlSocketServing: mcpListening,
            shellsReportingIntegration: shells, registeredAssistants: registered,
            remoteServerRunning: remote.localURL != nil, sshTabs: sshTabs)
    }
}

enum CommandSpecFactory {
    /// Runs `command` through a login zsh so Homebrew and other PATH setup applies.
    static func shell(_ command: String) -> CommandSpec {
        CommandSpec("/bin/zsh", ["-lc", command])
    }
}
