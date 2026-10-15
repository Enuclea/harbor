import Foundation
import HarborCore

/// What Harbor installs on a remote host so SSH tabs report status, exit codes and the
/// running command like local tabs do.
///
/// Scripts go to `~/.harbor/shell`; each shell's startup file gets a small, clearly
/// marked block that loads them only in *interactive* shells whose session carries
/// `LC_TERMINAL=Harbor`. Other terminals, scripts, scp/rsync and SFTP are unaffected.
public enum RemoteShellIntegration {
    /// Relative to the remote home directory.
    public static let directory = ".harbor/shell"
    public static let blockName = "harbor integration"
    public static let fishConfDPath = ".config/fish/conf.d/harbor.fish"

    /// The scripts that run on the host (the local launch bootstraps aren't needed there).
    public static func scripts() throws -> [(path: String, contents: Data)] {
        guard let root = Bundle.module.url(forResource: "integration", withExtension: nil) else {
            throw ShellIntegrationError.bundledScriptsMissing
        }
        var files: [(String, Data)] = []
        for path in ["zsh/harbor.zsh", "bash/harbor.bash", "fish/harbor.fish"] {
            files.append((path, try Data(contentsOf: root.appending(path: path))))
        }
        files.append(("VERSION", Data("\(AppIdentity.shellIntegrationVersion)\n".utf8)))
        return files
    }

    /// The startup file to edit for `shell`, relative to the remote home.
    public static func startupFile(for shell: ShellKind) -> String? {
        switch shell {
        case .zsh: ".zshrc"
        case .bash: ".bashrc"
        case .fish: fishConfDPath
        case .other: nil
        }
    }

    /// The managed-block body for zsh or bash, or the whole conf.d file for fish.
    public static func snippet(for shell: ShellKind) -> String? {
        let header = "# Added by \(AppIdentity.name). Loads only in interactive \(AppIdentity.name) sessions (LC_TERMINAL=\(AppIdentity.name))."
        switch shell {
        case .zsh:
            return """
                \(header)
                if [[ -o interactive && "${LC_TERMINAL-}" == \(AppIdentity.name) && -r "$HOME/\(directory)/zsh/harbor.zsh" ]]; then
                  HARBOR_SHELL_INTEGRATION_DIR="$HOME/\(directory)"
                  builtin source "$HOME/\(directory)/zsh/harbor.zsh"
                fi
                """
        case .bash:
            return """
                \(header)
                if [[ $- == *i* && "${LC_TERMINAL-}" == \(AppIdentity.name) && -r "$HOME/\(directory)/bash/harbor.bash" ]]; then
                  HARBOR_SHELL_INTEGRATION_DIR="$HOME/\(directory)"
                  builtin source "$HOME/\(directory)/bash/harbor.bash"
                fi
                """
        case .fish:
            return """
                \(header) Delete this file to undo.
                if status is-interactive; and test "$LC_TERMINAL" = \(AppIdentity.name); and test -r "$HOME/\(directory)/fish/harbor.fish"
                    set -gx HARBOR_SHELL_INTEGRATION_DIR "$HOME/\(directory)"
                    source "$HOME/\(directory)/fish/harbor.fish"
                end

                """
        case .other:
            return nil
        }
    }

    /// Which shells to configure: the login shell, plus any shell that already has a
    /// startup file (people often switch shells on servers).
    public static func shellsToConfigure(loginShell: String?, hasZshrc: Bool, hasBashrc: Bool, hasFishConfig: Bool) -> [ShellKind] {
        let login = loginShell.map(ShellKind.init(path:))
        var shells: [ShellKind] = []
        if login == .zsh || hasZshrc { shells.append(.zsh) }
        if login == .bash || hasBashrc { shells.append(.bash) }
        if login == .fish || hasFishConfig { shells.append(.fish) }
        return shells
    }

    /// Prints the login shell and whether `LC_TERMINAL` arrived, in a form that works in
    /// sh, bash, zsh, fish and csh.
    public static let probeCommand = "printenv SHELL; echo ---; printenv LC_TERMINAL; true"

    /// Parses `probeCommand` output into the login shell and whether the marker arrived.
    public static func parseProbe(_ output: String) -> (loginShell: String?, markerForwarded: Bool) {
        let parts = output.components(separatedBy: "---")
        let shell = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (shell?.isEmpty == false ? shell : nil, marker == AppIdentity.name)
    }
}
