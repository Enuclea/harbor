import Foundation
import HarborCore
import HarborHostSetup
import Testing

@Suite("GitHubScriptLibrary & #dnr Policy")
struct GitHubScriptLibraryTests {
    @Test("GitHubRepoSettings normalizes HTTPS and SSH repository URLs and derives Deploy Keys URL")
    func urlNormalization() {
        var settings = GitHubRepoSettings()
        settings.repositoryURL = "https://github.com/acme-sec/host-playbooks"
        #expect(settings.normalizedSSHURL == "git@github.com:acme-sec/host-playbooks.git")
        #expect(settings.webDeployKeysURL?.absoluteString == "https://github.com/acme-sec/host-playbooks/settings/keys")

        settings.repositoryURL = "git@github.com:acme-sec/host-playbooks.git"
        #expect(settings.normalizedSSHURL == "git@github.com:acme-sec/host-playbooks.git")
        #expect(settings.webDeployKeysURL?.absoluteString == "https://github.com/acme-sec/host-playbooks/settings/keys")
    }

    @Test("ScriptPlaybook parses @var, @secret, ${VAR:-default}, #dnr markers, and sanitizes for public release")
    func parseAndSanitizeDNR() {
        let source = """
        #!/usr/bin/env bash
        # @name: Default System Security
        # @description: Hardens SSH and firewall using variables only.
        # @category: security
        # @sudo: true
        # @var: SSH_PORT=2222 "Custom SSH port"
        # @secret: AUDIT_WEBHOOK_TOKEN "Optional webhook token"
        set -euo pipefail

        echo "Configuring port ${SSH_PORT:-2222} and ${EXTRA_ALLOW_PORT:-443}"
        ufw allow "${SSH_PORT}/tcp"
        ufw allow from 10.42.0.0/16 to any port "${SSH_PORT}" #dnr
        #dnr-start
        echo "Internal corp bastion rule"
        ufw allow from 172.16.0.0/12
        #dnr-end
        echo "Done"
        """
        let dummyURL = URL(fileURLWithPath: "/tmp/security/default-system-security.sh")
        let playbook = ScriptPlaybook.parse(
            fileURL: dummyURL,
            relativePath: "security/default-system-security.sh",
            contents: source
        )

        #expect(playbook.name == "Default System Security")
        #expect(playbook.category == "security")
        #expect(playbook.requiresSudo == true)
        #expect(playbook.interpreter == "bash")
        #expect(playbook.hasDNR == true)
        #expect(playbook.isFileDNR == false)
        #expect(!playbook.dnrLineNumbers.isEmpty)

        // Variables: SSH_PORT, AUDIT_WEBHOOK_TOKEN, EXTRA_ALLOW_PORT
        let varNames = playbook.variables.map(\.name)
        #expect(varNames.contains("SSH_PORT"))
        #expect(varNames.contains("AUDIT_WEBHOOK_TOKEN"))
        #expect(varNames.contains("EXTRA_ALLOW_PORT"))
        #expect(playbook.variables.first(where: { $0.name == "AUDIT_WEBHOOK_TOKEN" })?.isSecret == true)

        // Sanitize for public release: #dnr line and #dnr-start...#dnr-end block must be stripped
        let sanitized = ScriptPlaybook.sanitizeForPublicRelease(source)
        #expect(sanitized != nil)
        #expect(sanitized?.contains("10.42.0.0/16") == false)
        #expect(sanitized?.contains("172.16.0.0/12") == false)
        #expect(sanitized?.contains("Internal corp bastion rule") == false)
        #expect(sanitized?.contains("ufw allow \"${SSH_PORT}/tcp\"") == true)
        #expect(sanitized?.contains("echo \"Done\"") == true)

        // Whole-file # @dnr should return nil when sanitizing for public release
        let privateOnlyFile = """
        #!/bin/sh
        # @dnr
        echo "Strictly internal script"
        """
        #expect(ScriptPlaybook.sanitizeForPublicRelease(privateOnlyFile) == nil)

        // Command builder quotes variables safely
        let cmd = ScriptPlaybook.buildCommand(
            scriptPath: "/tmp/harbor-playbook-security.sh",
            interpreter: playbook.interpreter,
            requiresSudo: playbook.requiresSudo,
            variables: playbook.variables,
            values: ["SSH_PORT": "2200", "EXTRA_ALLOW_PORT": "8443"],
            cleanupAfter: true
        )
        #expect(cmd.contains("sudo SSH_PORT='2200' EXTRA_ALLOW_PORT='8443' bash '/tmp/harbor-playbook-security.sh'"))
        #expect(cmd.hasSuffix("rm -f '/tmp/harbor-playbook-security.sh'"))
    }

    @Test("GitHubScriptLibrary syncs from git repository, enforces read-only push URL, and exports public-safe split")
    @MainActor
    func syncAndExportPublicSplit() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("harbor-gh-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Create a local upstream git repository to simulate the remote GitHub repository
        let upstream = root.appendingPathComponent("upstream-repo", isDirectory: true)
        try fm.createDirectory(at: upstream.appendingPathComponent("security"), withIntermediateDirectories: true)

        let publicAndDNRScript = """
        #!/usr/bin/env bash
        # @name: Baseline Firewall
        # @var: SSH_PORT=22 "SSH Port"
        ufw allow "${SSH_PORT}/tcp"
        ufw allow from 10.99.0.0/16 #dnr
        """
        let privateOnlyScript = """
        #!/usr/bin/env bash
        # @name: Internal Bastion Setup
        # @dnr
        echo "Internal only"
        """
        try Data(publicAndDNRScript.utf8).write(to: upstream.appendingPathComponent("security/firewall.sh"))
        try Data(privateOnlyScript.utf8).write(to: upstream.appendingPathComponent("security/internal-only.sh"))

        _ = try await ProcessRunner.run("/usr/bin/git", ["init", "-b", "main", upstream.path], timeout: .seconds(5))
        _ = try await ProcessRunner.run("/usr/bin/git", ["-C", upstream.path, "config", "user.email", "test@example.com"], timeout: .seconds(5))
        _ = try await ProcessRunner.run("/usr/bin/git", ["-C", upstream.path, "config", "user.name", "Test"], timeout: .seconds(5))
        _ = try await ProcessRunner.run("/usr/bin/git", ["-C", upstream.path, "add", "."], timeout: .seconds(5))
        _ = try await ProcessRunner.run("/usr/bin/git", ["-C", upstream.path, "commit", "-m", "Initial scripts"], timeout: .seconds(5))

        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("AppSupport", isDirectory: true),
            logs: root.appendingPathComponent("Logs", isDirectory: true),
            sshControl: root.appendingPathComponent("ssh-ctl", isDirectory: true),
            home: root
        )
        try paths.ensureDirectories()

        let store = SettingsStore(store: JSONFileStore(url: paths.settingsFile, defaults: { AppSettings() }))
        store.settings.github.repositoryURL = upstream.path
        store.settings.github.branch = "main"

        let keychain = KeychainStore(service: "dev.harbor.tests.gh.\(UUID().uuidString)")
        let library = GitHubScriptLibrary(paths: paths, settings: store, keychain: keychain)

        let synced = try await library.sync()
        #expect(synced.count == 2)
        #expect(store.settings.github.lastSyncedCommit?.isEmpty == false)

        // Verify read-only push protection was set on the local clone
        let pushURL = try await ProcessRunner.run(
            "/usr/bin/git",
            ["-C", paths.githubScripts.path, "remote", "get-url", "--push", "origin"],
            timeout: .seconds(5)
        )
        #expect(pushURL.output.trimmingCharacters(in: .whitespacesAndNewlines) == "no_push_readonly")

        // Verify public-safe split export omits internal-only.sh and strips #dnr line from firewall.sh
        let exportDir = root.appendingPathComponent("public-export", isDirectory: true)
        let stats = try library.exportPublicSafeCopy(to: exportDir)
        #expect(stats.exportedFiles == 1)
        #expect(stats.omittedFiles == 1)
        #expect(stats.strippedLines == 1)

        let exportedFirewall = try String(contentsOf: exportDir.appendingPathComponent("security/firewall.sh"), encoding: .utf8)
        #expect(exportedFirewall.contains("ufw allow \"${SSH_PORT}/tcp\""))
        #expect(!exportedFirewall.contains("10.99.0.0/16"))
        #expect(!fm.fileExists(atPath: exportDir.appendingPathComponent("security/internal-only.sh").path))
    }

    @Test("Hardens shebang parsing, git URL validation, and subdirectory containment")
    @MainActor
    func securityHardeningChecks() async throws {
        // 1. Malicious or unsupported shebangs must fall back to "sh"
        let injectedShebang = ScriptPlaybook.parse(
            fileURL: URL(fileURLWithPath: "/tmp/bad.sh"),
            relativePath: "bad.sh",
            contents: "#!/bin/sh; rm -rf /\necho ok"
        )
        #expect(injectedShebang.interpreter == "sh")
        let command = ScriptPlaybook.buildCommand(
            scriptPath: "/tmp/bad.sh",
            interpreter: injectedShebang.interpreter,
            requiresSudo: false,
            variables: [],
            values: [:],
            cleanupAfter: true
        )
        #expect(command.contains("sh '/tmp/bad.sh'"))
        #expect(!command.contains("rm -rf /"))

        // 2. Repository URLs starting with '-' must be rejected to prevent git option injection
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("HarborGitHubSecTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let paths = AppPaths(
            applicationSupport: root.appendingPathComponent("AppSupport", isDirectory: true),
            logs: root.appendingPathComponent("Logs", isDirectory: true),
            sshControl: root.appendingPathComponent("ssh-ctl", isDirectory: true),
            home: root
        )
        try paths.ensureDirectories()
        let store = SettingsStore(store: JSONFileStore(url: paths.settingsFile, defaults: { AppSettings() }))
        store.settings.github.repositoryURL = "-oProxyCommand=evil"
        store.settings.github.branch = "main"
        let keychain = KeychainStore(service: "dev.harbor.tests.ghsec.\(UUID().uuidString)")
        let library = GitHubScriptLibrary(paths: paths, settings: store, keychain: keychain)
        await #expect(throws: GitHubScriptError.self) {
            _ = try await library.testConnection()
        }
        await #expect(throws: GitHubScriptError.self) {
            _ = try await library.sync()
        }

        // 3. scriptsSubdirectory traversal outside githubScripts must fall back to githubScripts root
        try fm.createDirectory(at: paths.githubScripts, withIntermediateDirectories: true)
        let secretScript = root.appendingPathComponent("outside.sh")
        try Data("#!/bin/sh\necho outside\n".utf8).write(to: secretScript)
        store.settings.github.scriptsSubdirectory = "../"
        library.reloadFromDisk()
        #expect(library.scripts.isEmpty)
    }
}
