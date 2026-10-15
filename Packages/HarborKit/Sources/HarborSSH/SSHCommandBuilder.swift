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

    /// The login for a terminal tab.
    public func interactive(_ host: HostProfile) -> CommandSpec {
        var arguments = sharingOptions(master: "auto") + keepAliveOptions + environmentOptions + hostOptions(host)
        var remoteCommand = host.startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if remoteCommand.isEmpty, host.remoteIntegration, host.remoteIntegrationMarker {
            remoteCommand = Self.markedLoginShell
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

    /// Forward Harbor's marker so remote shell integration knows it's in Harbor (in
    /// addition to macOS's default `SendEnv LANG LC_*`).
    private var environmentOptions: [String] {
        ["-o", "SendEnv=LC_TERMINAL"]
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
