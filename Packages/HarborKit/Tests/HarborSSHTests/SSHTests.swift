import Foundation
import HarborCore
@testable import HarborSSH
import Testing

@Suite("ssh_config parsing")
struct SSHConfigParserTests {
    @Test func parsesHostsAndSkipsPatterns() {
        let config = """
            # global
            ServerAliveInterval 60

            Host staging stage
                HostName 10.0.0.5
                User deploy
                Port 2222
                IdentityFile ~/.ssh/deploy_ed25519

            Host *.internal
                User ops

            Host bastion
              HostName=bastion.example.com
              ProxyJump jump@gw.example.com

            Match host foo
                User should-not-apply
            """
        let entries = SSHConfigParser.parse(config)
        #expect(entries.map(\.alias) == ["staging", "stage", "bastion"])
        #expect(entries[0] == SSHConfigEntry(alias: "staging", hostname: "10.0.0.5", user: "deploy", port: 2222,
                                             identityFile: "~/.ssh/deploy_ed25519"))
        #expect(entries[2].hostname == "bastion.example.com")
        #expect(entries[2].proxyJump == "jump@gw.example.com")
        #expect(entries[0].resolvedDestination == "deploy@10.0.0.5:2222")
    }

    @Test func firstValueWinsLikeSSH() {
        let entries = SSHConfigParser.parse("Host a\n  User first\n  User second\n")
        #expect(entries.first?.user == "first")
    }

    @Test func followsIncludes() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "harbor-ssh-\(UUID())")
        try FileManager.default.createDirectory(at: directory.appending(path: "config.d"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "Include config.d/*\nHost main\n  HostName main.example.com\n".write(to: directory.appending(path: "config"), atomically: true, encoding: .utf8)
        try "Host extra\n  HostName extra.example.com\n".write(to: directory.appending(path: "config.d/work"), atomically: true, encoding: .utf8)
        let entries = SSHConfigParser.load(from: directory.appending(path: "config"), sshDirectory: directory)
        #expect(Set(entries.map(\.alias)) == ["main", "extra"])
    }
}

@Suite("Destination parsing")
struct SSHDestinationTests {
    @Test(arguments: [
        ("example.com", nil, "example.com", nil),
        ("dan@example.com", "dan", "example.com", nil),
        ("dan@example.com:2222", "dan", "example.com", 2222),
        ("ssh://root@10.1.2.3:22/", "root", "10.1.2.3", 22),
        ("[2001:db8::1]:2200", nil, "2001:db8::1", 2200),
    ] as [(String, String?, String, Int?)])
    func parses(input: String, user: String?, host: String, port: Int?) throws {
        let profile = try SSHDestination.parse(input)
        #expect(profile.user == user)
        #expect(profile.hostname == host)
        #expect(profile.port == port)
    }

    @Test(arguments: ["-oProxyCommand=open -a Calculator", "host;rm -rf ~", "", "a@b:99999", "-l@host"])
    func rejectsDangerousOrInvalidInput(input: String) {
        #expect(throws: (any Error).self) { try SSHDestination.parse(input) }
    }

    @Test func validatorRejectsOptionInjectionInJumpHost() {
        let host = HostProfile(name: "x", hostname: "example.com", jumpHost: "-oProxyCommand=evil")
        #expect(HostProfileValidator.problems(in: host) == [.invalidJumpHost])
    }
}

@Suite("Command building")
struct SSHCommandBuilderTests {
    let builder = SSHCommandBuilder(settings: SSHSettings(), controlDirectory: URL(fileURLWithPath: "/Users/me/.ssh/harbor"))

    @Test func interactiveCommandSharesConnectionAndEndsOptions() {
        let host = HostProfile(name: "web", hostname: "web.example.com", user: "deploy", port: 2222,
                               identityFile: "/k/id", startupCommand: "tmux new -As main")
        let command = builder.interactive(host)
        #expect(command.executable == "/usr/bin/ssh")
        let args = command.arguments
        #expect(args.contains("ControlPath=/Users/me/.ssh/harbor/%C"))
        #expect(args.contains("ControlMaster=auto"))
        #expect(args.contains("-t"))
        let separator = try! #require(args.firstIndex(of: "--"))
        #expect(Array(args[separator...]) == ["--", "web.example.com", "tmux new -As main"])
        #expect(args.contains("IdentitiesOnly=yes"))
    }

    @Test func carriesTheHostsDisplayNameWhenAsked() {
        var host = HostProfile(name: "Nexus TX", hostname: "10.0.0.5", showsNameInPrompt: true)
        #expect(host.promptName == "Nexus TX")
        #expect(builder.interactive(host).arguments.contains("SendEnv=\(AppIdentity.hostNameVariable)"))

        // Servers that drop LC_* get the name exported with the marker instead.
        host.remoteIntegration = true
        host.remoteIntegrationMarker = true
        #expect(builder.interactive(host).arguments.last == #"export LC_TERMINAL=Harbor LC_HARBOR_HOST='Nexus TX'; exec "$SHELL" -l"#)
        host.showsNameInPrompt = false
        #expect(host.promptName == nil)
        #expect(builder.interactive(host).arguments.last == SSHCommandBuilder.markedLoginShell)
    }

    @Test func promptNamesKeepOnlyCharactersPromptsPrintLiterally() {
        #expect(HostProfile.promptSafe(#"a\b$c%d`e!f"#) == "a-b-c-d-e-f")
        #expect(HostProfile.promptSafe("  Café prod_1.2+x  ") == "Café prod_1.2+x")
        #expect(HostProfile(name: "  ", hostname: "h", showsNameInPrompt: true).promptName == nil)
    }

    @Test func sftpNeverPrompts() {
        let args = builder.sftpSubsystem(HostProfile(name: "a", hostname: "a.example.com")).arguments
        #expect(args.contains("BatchMode=yes"))
        #expect(args.suffix(4) == ["-s", "--", "a.example.com", "sftp"])
    }

    @Test func controlPathFitsUnixSocketLimit() {
        // macOS limits socket paths to 104 bytes; ssh adds a 17-char temp suffix and %C is 40 chars.
        let path = AppPaths.standard.sshControl.path + "/" + String(repeating: "a", count: 40) + ".XXXXXXXXXXXXXXXX"
        #expect(path.utf8.count < 104)
    }

    @Test func pathEscapingMatchesTerminalApp() {
        #expect(ShellQuoting.escapePath("/Users/me/My Files/a(1).txt") == "/Users/me/My\\ Files/a\\(1\\).txt")
        #expect(ShellQuoting.quote("it's") == "'it'\\''s'")
    }
}

@Suite("Key management")
struct SSHKeyManagerTests {
    @Test func generatesPassphraseProtectedKeyWithoutArgvSecrets() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "harbor-keys-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SSHKeyManager(sshDirectory: directory)

        let key = try await manager.generateKey(name: "id_test", comment: "harbor-test", passphrase: "correct horse")
        #expect(key.type == "ED25519")
        #expect(key.fingerprint.hasPrefix("SHA256:"))
        #expect(key.comment == "harbor-test")

        // The passphrase must actually protect the key.
        let wrong = try await ProcessRunner.run("/usr/bin/ssh-keygen", ["-y", "-P", "wrong", "-f", key.privateKeyPath])
        #expect(!wrong.succeeded)
        let right = try await ProcessRunner.run("/usr/bin/ssh-keygen", ["-y", "-P", "correct horse", "-f", key.privateKeyPath])
        #expect(right.succeeded)

        let listed = await manager.listKeys()
        #expect(listed.map(\.fileName) == ["id_test"])
    }

    @Test func refusesToOverwriteOrEscapeDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "harbor-keys-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SSHKeyManager(sshDirectory: directory)
        _ = try await manager.generateKey(name: "dup", comment: "", passphrase: nil)
        await #expect(throws: SSHKeyError.self) { _ = try await manager.generateKey(name: "dup", comment: "", passphrase: nil) }
        await #expect(throws: SSHKeyError.self) { _ = try await manager.generateKey(name: "../escape", comment: "", passphrase: nil) }
    }
}
