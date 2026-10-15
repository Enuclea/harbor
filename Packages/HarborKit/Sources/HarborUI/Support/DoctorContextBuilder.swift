import Foundation
import HarborDoctor
import HarborMCP
import HarborSSH

extension AppServices {
    /// Gathers the runtime facts diagnostics need.
    func actionsDoctorContext() async -> DoctorContext {
        let registered = await mcpRegistry.status().filter { $0.isRegistered && !$0.isStale }.map(\.app.displayName)
        let shells = Set(sessions.sessions.compactMap(\.shellIntegration))
        return DoctorContext(
            paths: paths, settings: settings.settings, appBundlePath: Bundle.main.bundlePath,
            bridgePath: Self.bridgePath, controlSocketServing: mcpListening,
            shellsReportingIntegration: shells, registeredAssistants: registered,
            remoteServerRunning: remote.localURL != nil)
    }
}

enum CommandSpecFactory {
    /// Runs `command` through a login zsh so Homebrew and other PATH setup applies.
    static func shell(_ command: String) -> CommandSpec {
        CommandSpec("/bin/zsh", ["-lc", command])
    }
}
