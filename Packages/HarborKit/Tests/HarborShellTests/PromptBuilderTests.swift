import Foundation
import HarborCore
@testable import HarborShell
import Testing

/// Runs a shell snippet in a throwaway HOME so the developer's dotfiles can't interfere.
private func runShell(_ shell: String, _ arguments: [String], in directory: URL, home: URL) async throws -> ProcessResult {
    try await ProcessRunner.run(
        shell, arguments,
        environment: ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8"],
        workingDirectory: directory, timeout: .seconds(20))
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "harbor-shell-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A git repository whose current branch name is a command-substitution payload.
private func makeHostileRepository(in root: URL) async throws -> URL {
    let repo = root.appending(path: "repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    for arguments in [["init", "-q"], ["checkout", "-q", "-b", "$(touch${IFS}pwned)"]] {
        let result = try await ProcessRunner.run("/usr/bin/git", arguments, workingDirectory: repo)
        #expect(result.succeeded, "git \(arguments): \(result.errorOutput)")
    }
    return repo
}

@Suite("Prompt builder")
struct PromptBuilderTests {
    @Test(arguments: PromptPreset.allCases)
    func zshPromptRendersAndIsSyntacticallyValid(preset: PromptPreset) async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "prompt.zsh")
        try #require(PromptBuilder.render(preset.config, for: .zsh)).write(to: file, atomically: true, encoding: .utf8)

        let script = "source '\(file.path)'; (( $+functions[_harbor_prompt_precmd] )) && _harbor_prompt_precmd; print -P -- \"$PROMPT\""
        let result = try await runShell("/bin/zsh", ["-f", "-c", script], in: root, home: root)
        #expect(result.succeeded, "\(result.errorOutput)")
        #expect(result.output.contains(preset.config.symbol))
    }

    @Test(arguments: PromptPreset.allCases)
    func bashPromptIsSyntacticallyValid(preset: PromptPreset) async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "prompt.bash")
        try #require(PromptBuilder.render(preset.config, for: .bash)).write(to: file, atomically: true, encoding: .utf8)
        let result = try await runShell("/bin/bash", ["--norc", "--noprofile", "-c", "source '\(file.path)' && { __harbor_prompt_build 1; echo \"$PS1\"; }"],
                                        in: root, home: root)
        #expect(result.succeeded, "\(result.errorOutput)")
        #expect(result.output.contains(preset.config.symbol))
    }

    @Test func hostileBranchNamesAreNotExecutedByZsh() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await makeHostileRepository(in: root)
        let file = root.appending(path: "prompt.zsh")
        try #require(PromptBuilder.render(PromptPreset.harbor.config, for: .zsh)).write(to: file, atomically: true, encoding: .utf8)

        let result = try await runShell("/bin/zsh", ["-f", "-c", "source '\(file.path)'; _harbor_prompt_precmd; print -P -- \"$PROMPT\""],
                                        in: repo, home: root)
        #expect(result.succeeded, "\(result.errorOutput)")
        #expect(result.output.contains("$(touch${IFS}pwned)"), "branch should be shown literally: \(result.output)")
        #expect(!FileManager.default.fileExists(atPath: repo.appending(path: "pwned").path))
    }

    @Test func hostileBranchNamesAreNotExecutedByBash() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await makeHostileRepository(in: root)
        let file = root.appending(path: "prompt.bash")
        try #require(PromptBuilder.render(PromptPreset.harbor.config, for: .bash)).write(to: file, atomically: true, encoding: .utf8)

        // An interactive bash expands PS1 for real; `exit` makes it draw one prompt and quit.
        let result = try await ProcessRunner.run(
            "/bin/bash", ["--norc", "--noprofile", "-i", "-c", "source '\(file.path)'; __harbor_prompt_build 0; echo \"${__harbor_p_git}\""],
            environment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "TERM": "dumb"], workingDirectory: repo)
        #expect(result.output.contains("$(touch${IFS}pwned)"))
        #expect(!FileManager.default.fileExists(atPath: repo.appending(path: "pwned").path))
    }

    @Test func fishPromptDefinesFunction() throws {
        let script = try #require(PromptBuilder.render(PromptPreset.developer.config, for: .fish))
        #expect(script.contains("function fish_prompt"))
        #expect(script.contains("set_color brblue"))
        #expect(script.hasSuffix("end\n"))
    }

    @Test func previewShowsErrorColourOnFailure() {
        let config = PromptPreset.harbor.config
        let ok = PromptPreview.lines(for: config, lastCommandFailed: false)
        let failed = PromptPreview.lines(for: config, lastCommandFailed: true)
        #expect(ok.last?.last?.color == config.symbolColor)
        #expect(failed.last?.last?.color == config.errorColor)
    }
}

@Suite("Shell launch planning")
struct ShellLaunchPlannerTests {
    let layout = ShellIntegrationLayout(root: URL(fileURLWithPath: "/tmp/harbor-shell"))

    @Test func zshUsesZDOTDIRAndPreservesUsers() {
        let plan = ShellLaunchPlanner(layout: layout).plan(
            shellPath: "/bin/zsh", loginShell: true, integration: true, promptScope: .harborSessions,
            inheritedEnvironment: ["ZDOTDIR": "/Users/me/.config/zsh"])
        #expect(plan.argv0 == "-zsh")
        #expect(plan.environment["ZDOTDIR"] == "/tmp/harbor-shell/zsh")
        #expect(plan.environment["HARBOR_ORIG_ZDOTDIR"] == "/Users/me/.config/zsh")
        #expect(plan.environment["HARBOR_PROMPT_FILE"] == "/tmp/harbor-shell/prompt.zsh")
    }

    @Test func bashUsesRCFileAndEmulatesLogin() {
        let plan = ShellLaunchPlanner(layout: layout).plan(
            shellPath: "/bin/bash", loginShell: true, integration: true, promptScope: .keepExisting, inheritedEnvironment: [:])
        #expect(plan.argv0 == "bash")
        #expect(plan.arguments == ["--rcfile", "/tmp/harbor-shell/bash/harbor-rc.bash"])
        #expect(plan.environment["HARBOR_BASH_LOGIN"] == "1")
        #expect(plan.environment["HARBOR_PROMPT_FILE"] == nil)
    }

    @Test func integrationDisabledLeavesShellAlone() {
        let plan = ShellLaunchPlanner(layout: layout).plan(
            shellPath: "/bin/zsh", loginShell: true, integration: false, promptScope: .harborSessions, inheritedEnvironment: [:])
        #expect(plan.environment.isEmpty)
        #expect(plan.arguments.isEmpty)
    }
}

@Suite("Managed rc blocks")
struct ManagedBlockTests {
    @Test func upsertIsIdempotentAndRemovable() {
        let original = "export PATH=/opt/bin:$PATH\n"
        let once = ManagedBlock.upsert(name: "harbor prompt", body: "source x", in: original)
        let twice = ManagedBlock.upsert(name: "harbor prompt", body: "source x", in: once)
        #expect(once == twice)
        #expect(once.contains("# >>> harbor prompt >>>\nsource x\n# <<< harbor prompt <<<"))
        #expect(ManagedBlock.remove(name: "harbor prompt", from: once).trimmingCharacters(in: .newlines)
                == original.trimmingCharacters(in: .newlines))
    }

    @Test func upsertReplacesStaleBody() {
        let stale = ManagedBlock.upsert(name: "harbor prompt", body: "old", in: "")
        let fresh = ManagedBlock.upsert(name: "harbor prompt", body: "new", in: stale)
        #expect(fresh.contains("new"))
        #expect(!fresh.contains("old"))
    }
}
