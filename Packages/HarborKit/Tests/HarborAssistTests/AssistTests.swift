import Foundation
import HarborAssist
import HarborCore
import HarborLogging
import Testing

@Suite("HarborAssist")
struct AssistTests {
    @Test("ContextBudgeter strips ANSI, redacts secrets, collapses duplicates, and truncates head/tail")
    func contextBudgeterPrepare() {
        let raw = """
        \u{1B}[32mStarting deployment...\u{1B}[0m
        Authorization: Bearer sk-secret-token-1234567890
        Retrying connection...
        Retrying connection...
        Retrying connection...
        Fatal error: ECONNREFUSED 127.0.0.1:5432
        """
        let prepared = ContextBudgeter.prepare(raw, maxTokens: 500)
        #expect(!prepared.text.contains("\u{1B}[32m"))
        #expect(!prepared.text.contains("sk-secret-token-1234567890"))
        #expect(prepared.text.contains("[repeated 3 times]"))
        #expect(prepared.text.contains("Fatal error: ECONNREFUSED"))

        // Verify head/tail truncation when budget is tight
        let longText = (1...200).map { "Line \($0): some log output from the build process" }.joined(separator: "\n")
        let truncated = ContextBudgeter.prepare(longText, maxTokens: 64)
        #expect(truncated.text.contains("Line 1:"))
        #expect(truncated.omittedLines > 0)
        #expect(truncated.text.contains("lines omitted to stay within"))
        #expect(truncated.text.contains("Line 200:"))
    }

    @Test("ContextBudgeter extracts last command output between OSC 133;C and 133;D")
    func extractLastCommandOutput() {
        let transcript = """
        \u{1B}]133;A\u{07}user@mac ~ % ls
        \u{1B}]133;C\u{07}file1.txt
        file2.txt
        \u{1B}]133;D;0\u{07}\u{1B}]133;A\u{07}user@mac ~ % cat missing.txt
        \u{1B}]133;C\u{07}cat: missing.txt: No such file or directory
        \u{1B}]133;D;1\u{07}
        """
        let extracted = ContextBudgeter.extractLastCommandOutput(from: Data(transcript.utf8))
        #expect(extracted == "cat: missing.txt: No such file or directory")
    }

    @Test("AssistService drafts commands, parses responses, and records token usage")
    @MainActor
    func assistServiceDraftAndExplain() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("settings.json")
        let store = SettingsStore(store: JSONFileStore(url: settingsURL, defaults: { AppSettings() }))
        store.settings.ai.onboard.enabled = true
        store.settings.ai.onboard.provider = .localOllama
        store.settings.ai.onboard.model = "qwen2.5-coder:7b"
        store.settings.ai.onboard.maxContextTokens = 1_000

        let transport: AIProviderClient.Transport = { request in
            let url = request.url?.absoluteString ?? ""
            #expect(url.contains("/chat/completions"))
            let responseJSON = """
            {
              "choices": [
                {
                  "message": {
                    "content": "COMMAND: lsof -iTCP:8080 -sTCP:LISTEN\\nEXPLANATION: Find processes listening on port 8080"
                  }
                }
              ],
              "usage": {
                "prompt_tokens": 84,
                "completion_tokens": 26
              }
            }
            """
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(responseJSON.utf8), http)
        }

        let keychain = KeychainStore(service: "dev.harbor.tests.\(UUID().uuidString)")
        let audit = AuditTrail(url: tempDir.appendingPathComponent("audit.jsonl"))
        let client = AIProviderClient(transport: transport)
        let service = AssistService(settings: store, keychain: keychain, audit: audit, client: client)

        let context = AssistContext(
            shell: "zsh",
            isRemote: false,
            hostLabel: nil,
            workingDirectory: "/tmp",
            lastCommand: nil,
            lastExitCode: nil,
            rawOutput: ""
        )
        let result = try await service.draftCommand(prompt: "find what is listening on 8080", context: context)
        #expect(result.suggestedCommand == "lsof -iTCP:8080 -sTCP:LISTEN")
        #expect(result.explanation.contains("8080"))
        #expect(service.ledger.totalTokens == 110)
        #expect(service.ledger.requestCount == 1)
    }

    @Test("Zero-token screen watcher detects failures and ignores clean command output")
    func detectCommandFailureFromScreenLines() {
        let notGitOutput = """
        dan@10.121.24.254:~$ git status
        fatal: not a git repository (or any of the parent directories): .git
        dan@10.121.24.254:~$
        """
        let reason = ContextBudgeter.detectCommandFailure(output: notGitOutput, command: "git status", exitCode: nil)
        #expect(reason?.contains("not a git repository") == true)

        let cleanOutput = """
        dan@10.121.24.254:~/repo$ git status
        On branch main
        nothing to commit, working tree clean
        dan@10.121.24.254:~/repo$
        """
        #expect(ContextBudgeter.detectCommandFailure(output: cleanOutput, command: "git status", exitCode: 0) == nil)
        #expect(ContextBudgeter.detectCommandFailure(output: cleanOutput, command: "git status", exitCode: nil) == nil)

        // Verify Cgit sanitization
        #expect(AssistService.sanitizeCommand("Cgit status") == "git status")
        #expect(AssistService.sanitizeCommand("C git status -sb") == "git status -sb")
        #expect(AssistService.sanitizeCommand("$ git status") == "git status")

        // Verify zero-token safe.directory built-in remedy extraction
        let dubiousOutput = """
        fatal: detected dubious ownership in repository at '/srv/app'
        To add an exception for this directory, call:

        \tgit config --global --add safe.directory /srv/app
        """
        let remedy = ContextBudgeter.extractBuiltInRemedy(output: dubiousOutput, failedCommand: "git status")
        #expect(remedy?.suggestedCommand == "git config --global --add safe.directory /srv/app && git status")
        #expect(remedy?.usage.totalTokens == 0)
        #expect(remedy?.explanation.contains("safe.directory") == true)
    }

    @Test("SystemProfile produces valid JSON locally and via the POSIX probe command")
    func systemProfileJSONRoundTripAndProbe() async throws {
        let local = SystemProfile.currentLocal(shell: "zsh", cwd: "/tmp")
        #expect(local.os == "Darwin")
        #expect(!local.arch.isEmpty)
        let json = local.compactJSON()
        let decoded = try #require(SystemProfile.decode(from: json))
        #expect(decoded.os == "Darwin")
        #expect(decoded.cwd == "/tmp")

        // Also run the POSIX sh probe command to verify it emits valid JSON.
        let result = try await ProcessRunner.run("/bin/sh", ["-c", SystemProfile.remoteProbeCommand], timeout: .seconds(5))
        #expect(result.succeeded)
        let probed = try #require(SystemProfile.decode(from: result.output))
        #expect(probed.os == "Darwin")
        #expect(!probed.arch.isEmpty)
    }
}
