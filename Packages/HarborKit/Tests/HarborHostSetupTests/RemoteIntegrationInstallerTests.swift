import Foundation
import HarborCore
import HarborFiles
@testable import HarborHostSetup
import HarborShell
import HarborSSH
import Testing

/// A throwaway "remote home" served by the real OpenSSH sftp-server.
private struct RemoteHome {
    let url: URL
    let files: RemoteFileBrowser

    init() throws {
        signal(SIGPIPE, SIG_IGN)
        url = FileManager.default.temporaryDirectory.appending(path: "harbor-remote-home-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let home = url.path
        files = RemoteFileBrowser(title: "test host") {
            try ProcessSFTPTransport(command: CommandSpec("/usr/libexec/sftp-server", ["-d", home]))
        }
    }

    func installer(loginShell: String, markerForwarded: Bool = true) -> RemoteIntegrationInstaller {
        let output = "\(loginShell)\n---\n\(markerForwarded ? AppIdentity.name : "")\n"
        return RemoteIntegrationInstaller(files: files) { command in
            #expect(command == RemoteShellIntegration.probeCommand)
            return ProcessResult(status: 0, stdout: Data(output.utf8), stderr: Data())
        }
    }

    func text(_ relative: String) throws -> String {
        try String(contentsOf: url.appending(path: relative), encoding: .utf8)
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: relative).path)
    }

    func permissions(_ relative: String) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.appending(path: relative).path)[.posixPermissions] as? Int ?? 0
    }

    /// Runs a shell as if logged in over SSH to this home.
    func run(_ shell: String, _ arguments: [String], marker: Bool) async throws -> ProcessResult {
        var environment = ["HOME": url.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
        if marker { environment["LC_TERMINAL"] = AppIdentity.name }
        return try await ProcessRunner.run(shell, arguments, environment: environment, workingDirectory: url, timeout: .seconds(20))
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

@Suite("Remote shell integration installer", .serialized)
struct RemoteIntegrationInstallerTests {
    @Test func installsScriptsAndBlockWithoutLosingUserConfig() async throws {
        let home = try RemoteHome()
        defer { home.remove() }
        let original = "export EDITOR=vim\nalias ll='ls -l'\n"
        try original.write(to: home.url.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: home.url.appending(path: ".zshrc").path)

        let report = try await home.installer(loginShell: "/bin/zsh").install()
        #expect(report.configuredShells == [.zsh])
        #expect(report.isCurrent)
        #expect(!report.needsMarker)

        for script in ["zsh/harbor.zsh", "bash/harbor.bash", "fish/harbor.fish", "VERSION"] {
            #expect(home.exists(".harbor/shell/\(script)"), "\(script)")
        }
        #expect(try home.permissions(".harbor") == 0o700)
        let zshrc = try home.text(".zshrc")
        #expect(zshrc.hasPrefix(original), "the user's config stays first and intact")
        #expect(zshrc.contains("# >>> harbor integration >>>"))
        #expect(try home.permissions(".zshrc") == 0o640, "existing permissions are kept")
        #expect(try home.text(".zshrc.harbor-backup") == original)

        // Installing again changes nothing.
        try await home.installer(loginShell: "/bin/zsh").install()
        #expect(try home.text(".zshrc") == zshrc)

        let inspected = try await home.installer(loginShell: "/bin/zsh").inspect()
        #expect(inspected.isInstalled)
        #expect(inspected.configuredShells == [.zsh])
    }

    @Test func zshLoadsOnlyInInteractiveHarborSessions() async throws {
        let home = try RemoteHome()
        defer { home.remove() }
        try await home.installer(loginShell: "/bin/zsh").install()
        let probe = "print -r -- \"loaded=${_HARBOR_INTEGRATION_LOADED-no}\""

        let harbor = try await home.run("/bin/zsh", ["-i", "-c", probe], marker: true)
        #expect(harbor.output.contains("loaded=1"), "\(harbor.output) \(harbor.errorOutput)")
        #expect(harbor.output.contains("\u{1b}]1337;HarborShellIntegration=zsh"))

        let otherTerminal = try await home.run("/bin/zsh", ["-i", "-c", probe], marker: false)
        #expect(otherTerminal.output.contains("loaded=no"))

        // Non-interactive (scp, rsync, scripts) must stay silent.
        let script = try await home.run("/bin/zsh", ["-c", "source ~/.zshrc; \(probe)"], marker: true)
        #expect(script.output == "loaded=no\n", "non-interactive output must be clean: \(script.output.debugDescription)")
    }

    @Test func bashLoadsOnlyInInteractiveHarborSessions() async throws {
        let home = try RemoteHome()
        defer { home.remove() }
        let report = try await home.installer(loginShell: "/bin/bash").install()
        #expect(report.configuredShells == [.bash])
        #expect(try home.permissions(".bashrc") == 0o644, "a new .bashrc is created readable")
        let probe = "echo \"loaded=${_HARBOR_INTEGRATION_LOADED-no}\""

        let harbor = try await home.run("/bin/bash", ["-i", "-c", probe], marker: true)
        #expect(harbor.output.contains("loaded=1"), "\(harbor.output) \(harbor.errorOutput)")
        let otherTerminal = try await home.run("/bin/bash", ["-i", "-c", probe], marker: false)
        #expect(otherTerminal.output.contains("loaded=no"))
        let script = try await home.run("/bin/bash", ["-c", "source ~/.bashrc; \(probe)"], marker: true)
        #expect(script.output == "loaded=no\n")
    }

    @Test func reportsWhenTheServerDropsTheMarker() async throws {
        let home = try RemoteHome()
        defer { home.remove() }
        let report = try await home.installer(loginShell: "/bin/bash", markerForwarded: false).install()
        #expect(report.needsMarker)
        #expect(report.summary.contains("doesn't accept LC_TERMINAL"))
    }

    @Test func uninstallRestoresTheUsersFiles() async throws {
        let home = try RemoteHome()
        defer { home.remove() }
        let original = "export PATH=$HOME/bin:$PATH\n"
        try original.write(to: home.url.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: home.url.appending(path: ".config/fish"), withIntermediateDirectories: true)

        let report = try await home.installer(loginShell: "/bin/zsh").install()
        #expect(report.configuredShells == [.zsh, .fish])
        #expect(home.exists(RemoteShellIntegration.fishConfDPath))

        try await home.installer(loginShell: "/bin/zsh").uninstall()
        #expect(try home.text(".zshrc").trimmingCharacters(in: .newlines) == original.trimmingCharacters(in: .newlines))
        #expect(!home.exists(".harbor/shell"))
        #expect(!home.exists(RemoteShellIntegration.fishConfDPath))
        #expect(!(try await home.installer(loginShell: "/bin/zsh").inspect()).isInstalled)
    }

    @Test func refusesUnsupportedShells() async throws {
        let home = try RemoteHome()
        defer { home.remove() }
        await #expect(throws: RemoteIntegrationError.self) {
            try await home.installer(loginShell: "/bin/tcsh").install()
        }
        #expect(!home.exists(".harbor"))
    }

    @Test func probeFailureExplainsHowToConnect() async throws {
        let home = try RemoteHome()
        defer { home.remove() }
        let installer = RemoteIntegrationInstaller(files: home.files) { _ in
            ProcessResult(status: 255, stdout: Data(), stderr: Data("Permission denied (publickey,password).".utf8))
        }
        do {
            try await installer.install()
            Issue.record("expected failure")
        } catch {
            #expect(error.localizedDescription.contains("Connect in a tab first"))
            #expect(error.localizedDescription.contains("Permission denied"))
        }
    }
}

@Suite("Remote integration plumbing")
struct RemoteIntegrationPlumbingTests {
    @Test func parsesProbeOutput() {
        #expect(RemoteShellIntegration.parseProbe("/usr/bin/zsh\n---\nHarbor\n") == ("/usr/bin/zsh", true))
        #expect(RemoteShellIntegration.parseProbe("/bin/bash\n---\n\n") == ("/bin/bash", false))
    }

    @Test func markerModeStartsTheLoginShellWithTheMarker() {
        let builder = SSHCommandBuilder(settings: SSHSettings(), controlDirectory: URL(fileURLWithPath: "/tmp/cm"))
        var host = HostProfile(name: "rhel", hostname: "rhel.example.com", remoteIntegration: true, remoteIntegrationMarker: true)
        let args = builder.interactive(host).arguments
        #expect(args.contains("SendEnv=LC_TERMINAL"))
        #expect(args.suffix(3) == ["--", "rhel.example.com", SSHCommandBuilder.markedLoginShell])
        #expect(args.contains("-t"))

        host.startupCommand = "tmux new -As main"
        #expect(builder.interactive(host).arguments.last == "tmux new -As main", "an explicit startup command wins")

        host.startupCommand = nil
        host.remoteIntegrationMarker = false
        #expect(builder.interactive(host).arguments.last == "rhel.example.com", "no remote command when the marker is forwarded")
    }
}
