import Foundation
import HarborCore
import HarborSSH

struct AssistantBridgeCheck: DiagnosticCheck {
    let id = "mcp"
    let title = "AI assistants (MCP)"

    func run(_ context: DoctorContext) async -> CheckResult {
        guard context.settings.ai.mcpEnabled else {
            return result(.info, "Assistant access is turned off.", remedy: Remedy("Turn on", .openSettings(section: "ai")))
        }
        guard FileManager.default.isExecutableFile(atPath: context.bridgePath) else {
            return result(.failure, "The harbor-mcp bridge is missing from the app bundle. Reinstall Harbor.")
        }
        guard context.controlSocketServing else {
            return result(.failure, "Harbor's control socket isn't listening, so assistants can't connect.",
                          detail: "Another copy of Harbor may be running. Quit it and relaunch.")
        }
        if context.registeredAssistants.isEmpty {
            return result(.info, "Ready. No assistant apps are connected yet.",
                          remedy: Remedy("Connect an assistant", .openSettings(section: "ai")))
        }
        return result(.pass, "Connected to \(context.registeredAssistants.joined(separator: ", ")).")
    }
}

struct RemoteAccessCheck: DiagnosticCheck {
    let id = "remote-access"
    let title = "Remote access"

    func run(_ context: DoctorContext) async -> CheckResult {
        let remote = context.settings.remote
        guard remote.enabled else { return result(.pass, "Off.") }
        guard context.remoteServerRunning else {
            return result(.failure, "Enabled, but the server isn't running. Port \(remote.port) may be in use.",
                          remedy: Remedy("Open Remote Access settings", .openSettings(section: "remote")))
        }
        let tool: (name: String, install: String)? = switch remote.tunnel {
        case .none: nil
        case .cloudflareQuick, .cloudflareNamed: ("cloudflared", "brew install cloudflared")
        case .tailscaleServe: ("tailscale", "brew install --cask tailscale")
        }
        if let tool, ExecutableLocator.find(tool.name) == nil {
            let install = CommandSpec("/bin/zsh", ["-lc", tool.install])
            return result(.failure, "\(tool.name) isn't installed.",
                          remedy: Remedy("Install \(tool.name)", .runInTerminal(install, title: "Install \(tool.name)")))
        }
        if remote.tunnel == .cloudflareQuick {
            return result(.warning, "Quick tunnels are public URLs protected only by your token.",
                          detail: "For everyday use, prefer Tailscale or a named Cloudflare tunnel behind Cloudflare Access.")
        }
        return result(.pass, remote.tunnel == .none ? "Listening on this Mac only." : "Published with \(remote.tunnel.label).")
    }
}
