import Foundation
import HarborCore
import HarborFiles
import HarborLogging
import HarborShell
import HarborSSH

/// The state of Harbor's shell integration on one host.
public struct RemoteIntegrationReport: Sendable, Equatable {
    /// The host's login shell, e.g. `/bin/bash`.
    public var loginShell: String?
    /// Whether the host's sshd accepted `LC_TERMINAL`. If not, Harbor must start the
    /// login shell with the marker set explicitly.
    public var markerForwarded: Bool
    public var installedVersion: Int?
    /// Shells whose startup files load the integration.
    public var configuredShells: [ShellKind]

    public init(loginShell: String?, markerForwarded: Bool, installedVersion: Int?, configuredShells: [ShellKind]) {
        self.loginShell = loginShell
        self.markerForwarded = markerForwarded
        self.installedVersion = installedVersion
        self.configuredShells = configuredShells
    }

    public var isInstalled: Bool { installedVersion != nil && !configuredShells.isEmpty }
    public var isCurrent: Bool { installedVersion == AppIdentity.shellIntegrationVersion }
    public var needsMarker: Bool { !markerForwarded }

    /// One sentence for the UI.
    public var summary: String {
        guard isInstalled else {
            return "Not installed. Commands you type on this host won't show on its tabs."
        }
        let shells = configuredShells.map(\.rawValue).joined(separator: ", ")
        var text = "Installed for \(shells)" + (isCurrent ? "." : " — an update is available.")
        if needsMarker {
            text += " This server doesn't accept LC_TERMINAL, so Harbor starts your shell with the marker (the login banner won't show)."
        }
        return text
    }
}

public enum RemoteIntegrationError: Error, LocalizedError {
    case probeFailed(String)
    case unsupportedShell(String)

    public var errorDescription: String? {
        switch self {
        case .probeFailed(let detail):
            "Couldn't run a command on the host. Connect in a tab first if it needs a password. (\(detail))"
        case .unsupportedShell(let shell):
            "\(shell) isn't supported. Harbor's integration works with zsh, bash and fish."
        }
    }
}

/// Installs, inspects and removes Harbor's shell integration on a remote host, using the
/// host's shared SSH connection for both file transfer and the environment probe.
public struct RemoteIntegrationInstaller: Sendable {
    let files: any RemoteFileAccess
    let execute: RemoteExecutor
    private let log = Log(.shell)

    public init(files: any RemoteFileAccess, execute: @escaping RemoteExecutor) {
        self.files = files
        self.execute = execute
    }

    // MARK: Inspect

    public func inspect() async throws -> RemoteIntegrationReport {
        let probe = try await runProbe()
        let home = try await files.homeDirectory()
        let version = try await files.readFile(path(home, RemoteShellIntegration.directory + "/VERSION"))
            .flatMap { Int(String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
        var configured: [ShellKind] = []
        for shell in [ShellKind.zsh, .bash, .fish] {
            if try await isConfigured(shell, home: home) { configured.append(shell) }
        }
        return RemoteIntegrationReport(loginShell: probe.loginShell, markerForwarded: probe.markerForwarded,
                                       installedVersion: version, configuredShells: configured)
    }

    // MARK: Install

    @discardableResult
    public func install() async throws -> RemoteIntegrationReport {
        let probe = try await runProbe()
        let home = try await files.homeDirectory()
        let shells = RemoteShellIntegration.shellsToConfigure(
            loginShell: probe.loginShell,
            hasZshrc: try await files.itemExists(path(home, ".zshrc")),
            hasBashrc: try await files.itemExists(path(home, ".bashrc")),
            hasFishConfig: try await files.itemExists(path(home, ".config/fish")))
        guard !shells.isEmpty else {
            throw RemoteIntegrationError.unsupportedShell(probe.loginShell ?? "The login shell")
        }

        // Scripts.
        let root = path(home, RemoteShellIntegration.directory)
        try await files.ensureDirectory(path(home, ".harbor"), permissions: 0o700)
        try await files.ensureDirectory(root, permissions: 0o755)
        for directory in ["zsh", "bash", "fish"] {
            try await files.ensureDirectory(path(root, directory), permissions: 0o755)
        }
        for script in try RemoteShellIntegration.scripts() {
            try await files.writeFile(path(root, script.path), contents: script.contents, permissions: 0o644)
        }

        // Startup files.
        for shell in shells {
            try await configure(shell, home: home)
        }
        log.notice("installed shell integration on host", ["shells": shells.map(\.rawValue).joined(separator: ","),
                                                            "marker": probe.markerForwarded ? "forwarded" : "explicit"])
        return RemoteIntegrationReport(loginShell: probe.loginShell, markerForwarded: probe.markerForwarded,
                                       installedVersion: AppIdentity.shellIntegrationVersion, configuredShells: shells)
    }

    // MARK: Uninstall

    public func uninstall() async throws {
        let home = try await files.homeDirectory()
        for shell in [ShellKind.zsh, .bash] {
            guard let relative = RemoteShellIntegration.startupFile(for: shell),
                  let data = try await files.readFile(path(home, relative)) else { continue }
            let original = String(decoding: data, as: UTF8.self)
            let updated = ManagedBlock.remove(name: RemoteShellIntegration.blockName, from: original)
            if updated != original {
                try await files.writeFile(path(home, relative), contents: Data(updated.utf8), permissions: nil)
            }
        }
        try await files.removeItem(path(home, RemoteShellIntegration.fishConfDPath))
        try await files.removeItem(path(home, RemoteShellIntegration.directory))
        log.notice("removed shell integration from host")
    }

    // MARK: Helpers

    private func runProbe() async throws -> (loginShell: String?, markerForwarded: Bool) {
        let result: ProcessResult
        do {
            result = try await execute(RemoteShellIntegration.probeCommand)
        } catch {
            throw RemoteIntegrationError.probeFailed(error.localizedDescription)
        }
        guard result.succeeded else {
            throw RemoteIntegrationError.probeFailed(result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return RemoteShellIntegration.parseProbe(result.output)
    }

    private func configure(_ shell: ShellKind, home: String) async throws {
        guard let relative = RemoteShellIntegration.startupFile(for: shell),
              let snippet = RemoteShellIntegration.snippet(for: shell) else { return }
        let target = path(home, relative)
        if shell == .fish {
            for directory in [".config", ".config/fish", ".config/fish/conf.d"] {
                try await files.ensureDirectory(path(home, directory), permissions: 0o755)
            }
            try await files.writeFile(target, contents: Data(snippet.utf8), permissions: 0o644)
            return
        }
        let existing = try await files.readFile(target)
        let original = existing.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let updated = ManagedBlock.upsert(name: RemoteShellIntegration.blockName, body: snippet, in: original)
        guard updated != original else { return }
        // Keep one pristine copy of the user's file from before Harbor first touched it.
        let backup = target + ".harbor-backup"
        if let existing, !existing.isEmpty, try await !files.itemExists(backup) {
            try await files.writeFile(backup, contents: existing, permissions: 0o600)
        }
        try await files.writeFile(target, contents: Data(updated.utf8), permissions: existing == nil ? 0o644 : nil)
    }

    private func isConfigured(_ shell: ShellKind, home: String) async throws -> Bool {
        guard let relative = RemoteShellIntegration.startupFile(for: shell) else { return false }
        if shell == .fish { return try await files.itemExists(path(home, relative)) }
        guard let data = try await files.readFile(path(home, relative)) else { return false }
        return String(decoding: data, as: UTF8.self).contains("# >>> \(RemoteShellIntegration.blockName) >>>")
    }

    private func path(_ base: String, _ relative: String) -> String {
        RemotePath.join(base, relative)
    }
}

extension RemoteIntegrationInstaller {
    /// An installer that talks to `host` over its shared SSH connection.
    public static func ssh(host: HostProfile, builder: SSHCommandBuilder) -> (RemoteIntegrationInstaller, RemoteFileBrowser) {
        let browser = RemoteFileBrowser.ssh(host: host, builder: builder)
        return (RemoteIntegrationInstaller(files: browser, execute: builder.executor(for: host)), browser)
    }
}
