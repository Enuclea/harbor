import Foundation
import HarborCore

/// An executable plus its arguments.
public struct CommandSpec: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]

    public init(_ executable: String, _ arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// Shell-quoted rendering, for logs and "copy command".
    public var displayString: String {
        ([executable] + arguments).map(ShellQuoting.quote).joined(separator: " ")
    }
}

/// Builds every `ssh` invocation Harbor makes.
///
/// All of them share one ControlMaster socket per destination, so the interactive tab,
/// the file flyout, key installation and extra tabs authenticate once.
public struct SSHCommandBuilder: Sendable {
    public var sshPath: String
    public var controlDirectory: URL
    public var connectionSharing: Bool
    public var persistSeconds: Int
    public var serverAliveInterval: Int
    public var forwardAgentByDefault: Bool

    public init(settings: SSHSettings, controlDirectory: URL) {
        sshPath = settings.sshPath
        self.controlDirectory = controlDirectory
        connectionSharing = settings.connectionSharing
        persistSeconds = settings.connectionPersistSeconds
        serverAliveInterval = settings.serverAliveInterval
        forwardAgentByDefault = settings.forwardAgentByDefault
    }

    /// `%C` is a hash of local host, remote host, port, user and jump host — short and unique.
    public var controlPath: String { controlDirectory.path + "/%C" }

    /// Starts the remote login shell with Harbor's marker exported, for hosts whose sshd
    /// doesn't accept `LC_TERMINAL`. Works for sh, bash, zsh and fish login shells.
    public static let markedLoginShell = #"export LC_TERMINAL=Harbor; exec "$SHELL" -l"#

    /// `markedLoginShell`, also exporting the host's display name for the prompt.
    public static func markedLoginShell(promptName: String?) -> String {
        guard let promptName else { return markedLoginShell }
        return #"export LC_TERMINAL=Harbor \#(AppIdentity.hostNameVariable)=\#(ShellQuoting.quote(promptName)); exec "$SHELL" -l"#
    }

    /// The login for a terminal tab.
    public func interactive(_ host: HostProfile) -> CommandSpec {
        var arguments = sharingOptions(master: "auto") + keepAliveOptions + ["-o", "ConnectTimeout=15"]
            + environmentOptions + hostOptions(host) + autoForwardOptions(host)
        var remoteCommand = host.startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if remoteCommand.isEmpty, host.remoteIntegration, host.remoteIntegrationMarker {
            remoteCommand = Self.markedLoginShell(promptName: host.promptName)
        }
        if !remoteCommand.isEmpty { arguments.append("-t") }
        arguments += ["--", host.hostname]
        if !remoteCommand.isEmpty { arguments.append(remoteCommand) }
        return CommandSpec(sshPath, arguments)
    }

    /// Runs one non-interactive command on the host over the shared connection, never
    /// prompting (it fails instead).
    public func remoteCommand(_ command: String, on host: HostProfile) -> CommandSpec {
        let arguments = sharingOptions(master: "auto") + keepAliveOptions + environmentOptions + hostOptions(host)
            + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-T", "--", host.hostname, command]
        return CommandSpec(sshPath, arguments)
    }

    /// A raw SFTP channel (`-s … sftp`) that never prompts: it rides the tab's master
    /// connection, or succeeds on its own only with key authentication.
    public func sftpSubsystem(_ host: HostProfile) -> CommandSpec {
        let arguments = sharingOptions(master: "auto") + keepAliveOptions + hostOptions(host)
            + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-T", "-s", "--", host.hostname, "sftp"]
        return CommandSpec(sshPath, arguments)
    }

    /// Asks the master for `host` whether it is alive (`ssh -O check`).
    public func controlCheck(_ host: HostProfile) -> CommandSpec {
        CommandSpec(sshPath, ["-o", "ControlPath=\(controlPath)"] + hostOptions(host) + ["-O", "check", "--", host.hostname])
    }

    /// Closes the shared connection for `host`.
    public func controlExit(_ host: HostProfile) -> CommandSpec {
        CommandSpec(sshPath, ["-o", "ControlPath=\(controlPath)"] + hostOptions(host) + ["-O", "exit", "--", host.hostname])
    }

    /// Requests a live port forward (`-L`, `-R`) or dynamic SOCKS5 proxy (`-D`) on the existing
    /// shared master connection (`ssh -O forward ...`).
    public func controlForward(_ rule: PortForwardRule, on host: HostProfile) -> CommandSpec {
        let args = ["-o", "ControlPath=\(controlPath)"] + hostOptions(host)
            + ["-O", "forward"] + rule.sshArguments + ["--", host.hostname]
        return CommandSpec(sshPath, args)
    }

    /// Cancels a live port forward (`-L`, `-R`) or dynamic SOCKS5 proxy (`-D`) on the existing
    /// shared master connection (`ssh -O cancel ...`).
    public func controlCancel(_ rule: PortForwardRule, on host: HostProfile) -> CommandSpec {
        let args = ["-o", "ControlPath=\(controlPath)"] + hostOptions(host)
            + ["-O", "cancel"] + rule.sshArguments + ["--", host.hostname]
        return CommandSpec(sshPath, args)
    }

    /// Evaluates OpenSSH configuration (`ssh -G`) for `host` to resolve aliases, ports, and proxy jumps.
    public func resolveConfig(_ host: HostProfile) -> CommandSpec {
        CommandSpec(sshPath, hostOptions(host) + ["-G", "--", host.hostname])
    }

    /// Parses the output of `ssh -G` to extract the effective target hostname, port, and whether a proxy/jump is active.
    public static func parseEffectiveTarget(from sshGOutput: String, fallback: HostProfile) -> (hostname: String, port: Int, hasProxyOrJump: Bool) {
        var hostname = fallback.hostname
        var port = fallback.port ?? 22
        var hasProxyOrJump = !(fallback.jumpHost ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        for rawLine in sshGOutput.split(whereSeparator: \.isNewline) {
            let parts = rawLine.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let val = String(parts[1]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "hostname":
                if !val.isEmpty { hostname = val }
            case "port":
                if let p = Int(val) { port = p }
            case "proxyjump", "proxycommand":
                if !val.isEmpty, val.lowercased() != "none" {
                    hasProxyOrJump = true
                }
            default:
                break
            }
        }
        return (hostname, port, hasProxyOrJump)
    }

    /// Installs a public key on `host`. Runs in a visible tab so the user can answer any
    /// password prompt themselves; with a live master it completes without prompting.
    public func installPublicKey(_ publicKeyPath: String, on host: HostProfile) -> CommandSpec {
        var options = sharingOptions(master: "auto")
        if let port = host.port { options += ["-p", String(port)] }
        let destination = host.user.map { "\($0)@\(host.hostname)" } ?? host.hostname
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-copy-id") {
            return CommandSpec("/usr/bin/ssh-copy-id", ["-i", publicKeyPath] + options + [destination])
        }
        // Fallback for systems without ssh-copy-id.
        let remote = "umask 077; mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
        let script = "\(ShellQuoting.quote(sshPath)) \(options.map(ShellQuoting.quote).joined(separator: " ")) -- "
            + "\(ShellQuoting.quote(destination)) \(ShellQuoting.quote(remote)) < \(ShellQuoting.quote(publicKeyPath))"
        return CommandSpec("/bin/sh", ["-c", script])
    }

    // MARK: Option groups

    private func sharingOptions(master: String) -> [String] {
        guard connectionSharing else { return [] }
        return [
            "-o", "ControlMaster=\(master)",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=\(max(0, persistSeconds))",
        ]
    }

    /// Forward Harbor's marker so remote shell integration knows it's in Harbor, and the
    /// host's display name when the tab sets one (in addition to macOS's default
    /// `SendEnv LANG LC_*`). ssh sends only variables that are set.
    private var environmentOptions: [String] {
        ["-o", "SendEnv=LC_TERMINAL", "-o", "SendEnv=\(AppIdentity.hostNameVariable)"]
    }

    private var keepAliveOptions: [String] {
        guard serverAliveInterval > 0 else { return [] }
        return ["-o", "ServerAliveInterval=\(serverAliveInterval)", "-o", "ServerAliveCountMax=3"]
    }

    /// Options derived from the profile. Explicit fields override `~/.ssh/config`.
    private func hostOptions(_ host: HostProfile) -> [String] {
        var options: [String] = []
        if let port = host.port { options += ["-p", String(port)] }
        if let user = host.user, !user.isEmpty { options += ["-l", user] }
        if let identity = host.identityFile, !identity.isEmpty {
            options += ["-i", (identity as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        if let jump = host.jumpHost, !jump.isEmpty { options += ["-J", jump] }
        if host.forwardAgent || forwardAgentByDefault { options.append("-A") }
        return options
    }

    /// Port forwards and SOCKS proxies configured to start automatically when connecting to `host`.
    private func autoForwardOptions(_ host: HostProfile) -> [String] {
        host.portForwards
            .filter { $0.autoStart && HostProfileValidator.isValidForward($0) }
            .flatMap(\.sshArguments)
    }
}

/// POSIX shell quoting.
public enum ShellQuoting {
    public static func quote(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quotes a path for pasting into an interactive shell (Terminal.app drag-and-drop style).
    public static func escapePath(_ path: String) -> String {
        var result = ""
        for character in path {
            if " \t\n\\'\"`$&*?;|<>()[]{}!#~^".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
