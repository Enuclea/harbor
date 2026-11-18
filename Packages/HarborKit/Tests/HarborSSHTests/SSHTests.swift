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

    @Test func validatorRejectsInvalidPortForwards() {
        let badPort = PortForwardRule(kind: .local, listenPort: 70_000, targetPort: 80)
        let badAddr = PortForwardRule(kind: .local, bindAddress: "-oEvil=1", listenPort: 8080, targetPort: 80)
        #expect(HostProfileValidator.problems(in: HostProfile(name: "x", hostname: "example.com", portForwards: [badPort])) == [.invalidPortForward])
        #expect(HostProfileValidator.problems(in: HostProfile(name: "x", hostname: "example.com", portForwards: [badAddr])) == [.invalidPortForward])
    }
}

@Suite("Quick redirect and proxy parsing")
struct PortForwardRuleTests {
    @Test func parsesLocalRedirects() throws {
        let single = try PortForwardRule.parse("8080")
        #expect(single.kind == .local)
        #expect(single.sshArguments == ["-L", "127.0.0.1:8080:127.0.0.1:8080"])
        #expect(single.displaySummary == "localhost:8080 → 8080")

        let pair = try PortForwardRule.parse("8080->3000")
        #expect(pair.sshArguments == ["-L", "127.0.0.1:8080:127.0.0.1:3000"])
        #expect(pair.displaySummary == "localhost:8080 → 3000")

        let hostTarget = try PortForwardRule.parse("5432:db.internal:5432")
        #expect(hostTarget.sshArguments == ["-L", "127.0.0.1:5432:db.internal:5432"])
        #expect(hostTarget.displaySummary == "localhost:5432 → db.internal:5432")

        let fourPart = try PortForwardRule.parse("0.0.0.0:8080:10.0.0.2:80")
        #expect(fourPart.sshArguments == ["-L", "0.0.0.0:8080:10.0.0.2:80"])

        let ipPortCombo = try PortForwardRule.parse("192.168.88.1:8291")
        #expect(ipPortCombo.sshArguments == ["-L", "127.0.0.1:8291:192.168.88.1:8291"])
        #expect(ipPortCombo.displaySummary == "localhost:8291 → 192.168.88.1:8291")
        #expect(HostProfileValidator.isValidForward(ipPortCombo))

        let ipv6Target = try PortForwardRule.parse("[2001:db8::1]:8291")
        #expect(ipv6Target.sshArguments == ["-L", "127.0.0.1:8291:[2001:db8::1]:8291"])
        #expect(ipv6Target.displaySummary == "localhost:8291 → [2001:db8::1]:8291")
        #expect(HostProfileValidator.isValidForward(ipv6Target))
    }

    @Test func buildsStructuredBastionHostPortRedirects() throws {
        // Local port + remote IP:port combo (e.g. Winbox behind a bastion)
        let samePort = try PortForwardRule.build(kind: .local, localInput: "8291", remoteInput: "192.168.88.1:8291")
        #expect(samePort.sshArguments == ["-L", "127.0.0.1:8291:192.168.88.1:8291"])

        // Custom local port + remote IP:port combo
        let mappedPort = try PortForwardRule.build(kind: .local, localInput: "18291", remoteInput: "10.10.0.1:8291")
        #expect(mappedPort.sshArguments == ["-L", "127.0.0.1:18291:10.10.0.1:8291"])
        #expect(mappedPort.displaySummary == "localhost:18291 → 10.10.0.1:8291")

        // Blank local port + remote IP:port combo (defaults local port to remote port)
        let remoteOnly = try PortForwardRule.build(kind: .local, localInput: "", remoteInput: "192.168.88.1:8291")
        #expect(remoteOnly.sshArguments == ["-L", "127.0.0.1:8291:192.168.88.1:8291"])

        // Local port + bare remote IP (defaults remote port to local port)
        let bareIP = try PortForwardRule.build(kind: .local, localInput: "8291", remoteInput: "192.168.88.1")
        #expect(bareIP.sshArguments == ["-L", "127.0.0.1:8291:192.168.88.1:8291"])

        // IP:port entered in targetHostInput field
        let targetFieldCombo = try PortForwardRule.build(
            kind: .local,
            localInput: "18291",
            remoteInput: "",
            targetHostInput: "192.168.88.1:8291"
        )
        #expect(targetFieldCombo.sshArguments == ["-L", "127.0.0.1:18291:192.168.88.1:8291"])

        // Bracketed IPv6 in remoteInput
        let ipv6Built = try PortForwardRule.build(kind: .local, localInput: "8291", remoteInput: "[fd00::1]:8291")
        #expect(ipv6Built.sshArguments == ["-L", "127.0.0.1:8291:[fd00::1]:8291"])
        #expect(HostProfileValidator.isValidForward(ipv6Built))

        // Reverse (-R) with LAN IP:port on Mac side
        let reverseLAN = try PortForwardRule.build(kind: .remote, localInput: "192.168.1.50:8080", remoteInput: "9000")
        #expect(reverseLAN.sshArguments == ["-R", "127.0.0.1:9000:192.168.1.50:8080"])
    }

    @Test func parsesRemoteRedirectsAndDynamicSocks() throws {
        let remote = try PortForwardRule.parse("-R 9000:3000")
        #expect(remote.kind == .remote)
        #expect(remote.sshArguments == ["-R", "127.0.0.1:9000:127.0.0.1:3000"])
        #expect(remote.displaySummary == "remote:9000 → localhost:3000")

        let socks = try PortForwardRule.parse("socks 1080", label: "SOCKS")
        #expect(socks.kind == .dynamic)
        #expect(socks.sshArguments == ["-D", "127.0.0.1:1080"])
        #expect(socks.displaySummary == "SOCKS5 localhost:1080")
        #expect(socks.copyableSnippet == "ALL_PROXY=socks5h://127.0.0.1:1080")

        let socksURL = try PortForwardRule.parse("socks5://1081")
        #expect(socksURL.kind == .dynamic)
        #expect(socksURL.listenPort == 1081)
    }

    @Test(arguments: ["", "0", "99999", "8080:-oEvil:80", "a:b:c:d:e"])
    func rejectsInvalidSpecs(spec: String) {
        #expect(throws: PortForwardParseError.self) {
            try PortForwardRule.parse(spec)
        }
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
        #expect(args.contains("ConnectTimeout=15"))
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

    @Test func buildsAutoForwardAndLiveControlForwardCommands() throws {
        let localRule = try PortForwardRule.parse("8080:3000")
        let socksRule = try PortForwardRule.parse("socks 1080")
        var disabledRule = try PortForwardRule.parse("5432")
        disabledRule.autoStart = false

        let host = HostProfile(
            name: "app",
            hostname: "app.example.com",
            user: "dan",
            portForwards: [localRule, socksRule, disabledRule]
        )

        let interactiveArgs = builder.interactive(host).arguments
        #expect(interactiveArgs.contains("-L"))
        #expect(interactiveArgs.contains("127.0.0.1:8080:127.0.0.1:3000"))
        #expect(interactiveArgs.contains("-D"))
        #expect(interactiveArgs.contains("127.0.0.1:1080"))
        #expect(!interactiveArgs.contains("127.0.0.1:5432:127.0.0.1:5432"))

        let forwardArgs = builder.controlForward(localRule, on: host).arguments
        #expect(forwardArgs.suffix(6) == ["-O", "forward", "-L", "127.0.0.1:8080:127.0.0.1:3000", "--", "app.example.com"])

        let cancelArgs = builder.controlCancel(socksRule, on: host).arguments
        #expect(cancelArgs.suffix(6) == ["-O", "cancel", "-D", "127.0.0.1:1080", "--", "app.example.com"])
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
