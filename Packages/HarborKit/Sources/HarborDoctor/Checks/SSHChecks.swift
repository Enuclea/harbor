import Foundation
import HarborCore
import HarborSSH

/// ssh refuses private keys that others can read, and warns about a loose ~/.ssh.
struct SSHDirectoryCheck: DiagnosticCheck {
    let id = "ssh-permissions"
    let title = "SSH folder permissions"

    func run(_ context: DoctorContext) async -> CheckResult {
        let directory = context.paths.sshDirectory
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path) else {
            return result(.info, "~/.ssh doesn't exist yet. Harbor creates it when you add a key.")
        }
        let mode = (attributes[.posixPermissions] as? Int) ?? 0
        if mode & 0o077 != 0 {
            return result(.warning, "~/.ssh is readable by other users (mode \(String(mode, radix: 8))).",
                          remedy: Remedy("Set to 700", .fixPermissions(path: directory.path, mode: 0o700)))
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where !file.hasSuffix(".pub") && (file.hasPrefix("id_") || file.hasSuffix(".pem") || file.hasSuffix("_key")) {
            let path = directory.appending(path: file).path
            let fileMode = ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int) ?? 0
            if fileMode & 0o077 != 0 {
                return result(.failure, "\(file) is readable by others, so ssh will refuse to use it.",
                              remedy: Remedy("Set to 600", .fixPermissions(path: path, mode: 0o600)))
            }
        }
        return result(.pass, "~/.ssh and private keys are private.")
    }
}

struct SSHAgentCheck: DiagnosticCheck {
    let id = "ssh-agent"
    let title = "SSH agent"

    func run(_ context: DoctorContext) async -> CheckResult {
        guard ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] != nil else {
            return result(.warning, "No SSH agent is available to Harbor.",
                          detail: "macOS normally provides one. If you use 1Password or Secretive, set IdentityAgent in ~/.ssh/config.")
        }
        guard let output = try? await ProcessRunner.run("/usr/bin/ssh-add", ["-l"], timeout: .seconds(5)) else {
            return result(.warning, "Couldn't query the SSH agent.")
        }
        switch output.status {
        case 0:
            let count = output.output.split(separator: "\n").count
            return result(.pass, "\(count) key\(count == 1 ? "" : "s") loaded.")
        case 1:
            return result(.info, "The agent has no keys loaded. Keys with passphrases will prompt on first use.",
                          remedy: Remedy("Manage keys", .openSettings(section: "keys")))
        default:
            return result(.warning, "The SSH agent isn't responding.", detail: output.errorOutput)
        }
    }
}

struct ConnectionSharingCheck: DiagnosticCheck {
    let id = "connection-sharing"
    let title = "Connection sharing"

    func run(_ context: DoctorContext) async -> CheckResult {
        guard context.settings.ssh.connectionSharing else {
            return result(.info, "Off. The file browser will sign in separately and may fail for password-only hosts.",
                          remedy: Remedy("Turn on", .openSettings(section: "ssh")))
        }
        let directory = context.paths.sshControl
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            return result(.failure, "\(directory.path) isn't writable, so ssh can't share connections.",
                          remedy: Remedy("Fix permissions", .fixPermissions(path: directory.path, mode: 0o700)))
        }
        // Socket paths are limited to 104 bytes; ssh adds a 17-byte suffix while creating one.
        let worstCase = directory.path.utf8.count + 1 + 40 + 17
        if worstCase >= 104 {
            return result(.failure, "The connection-sharing path is too long for a Unix socket (\(worstCase) bytes).")
        }
        return result(.pass, "One sign-in per host is shared by tabs and the file browser.")
    }
}
