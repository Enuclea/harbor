import Foundation
import HarborCore
import HarborLogging
import Observation

/// Onboard AI force multiplier: user- and event-triggered command drafting, error/log parsing,
/// continuation suggestions, and background alert summaries.
@MainActor
@Observable
public final class AssistService {
    public let ledger = TokenLedger()
    private let settings: SettingsStore
    private let keychain: KeychainStore
    private let audit: AuditTrail
    private let client: AIProviderClient
    private let log = Log(.assist)

    public init(
        settings: SettingsStore,
        keychain: KeychainStore,
        audit: AuditTrail,
        client: AIProviderClient = AIProviderClient()
    ) {
        self.settings = settings
        self.keychain = keychain
        self.audit = audit
        self.client = client
    }

    public var config: OnboardAISettings {
        settings.settings.ai.onboard
    }

    public var isReady: Bool {
        let cfg = config
        guard cfg.enabled else { return false }
        return !cfg.provider.requiresAPIKey || hasConfiguredKey(for: cfg.provider)
    }

    // MARK: Keychain management

    public func hasConfiguredKey(for provider: AIProviderKind) -> Bool {
        guard provider.requiresAPIKey else { return true }
        let account = "onboard-ai.\(provider.rawValue)"
        let stored = (try? keychain.string(for: account))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored?.isEmpty == false
    }

    public func saveAPIKey(_ key: String, for provider: AIProviderKind) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = "onboard-ai.\(provider.rawValue)"
        if trimmed.isEmpty {
            try keychain.remove(account)
        } else {
            try keychain.set(trimmed, for: account)
        }
    }

    public func removeAPIKey(for provider: AIProviderKind) throws {
        let account = "onboard-ai.\(provider.rawValue)"
        try keychain.remove(account)
    }

    private func loadAPIKey(for provider: AIProviderKind) -> String? {
        try? keychain.string(for: "onboard-ai.\(provider.rawValue)")
    }

    // MARK: Operations

    /// Verifies connectivity and credentials with a minimal token ping.
    public func testConnection() async throws -> String {
        let cfg = config
        let response = try await client.complete(
            system: "Reply with the single word OK.",
            user: "Ping",
            settings: cfg,
            apiKey: loadAPIKey(for: cfg.provider)
        )
        ledger.record(response.usage)
        return "Connected to \(cfg.effectiveModel) (\(response.usage.totalTokens) tokens)"
    }

    /// Translates a natural-language request into a shell command for the current session.
    public func draftCommand(prompt: String, context: AssistContext) async throws -> AssistResult {
        let cfg = config
        guard cfg.enabled else { throw AssistError.disabled }
        let screenSlice = ContextBudgeter.prepare(context.rawOutput, maxTokens: min(cfg.maxContextTokens, 240))
        let system = """
        You are Harbor's built-in terminal assistant. Respond strictly in this two-part format:
        COMMAND: <single-line shell command>
        EXPLANATION: <one concise sentence>
        Target shell: \(context.shell). Environment: \(context.isRemote ? "Remote SSH (\(context.hostLabel ?? "server"))" : "macOS").
        Use the provided `System Profile (JSON)` (`uname`, OS distro, arch, packageManager, initSystem, available tools, cwd, and gitState) and `Recent screen lines` to tailor flags and tools to this exact system.
        If `gitState` is "untrusted-safe-directory" and the command uses git, prepend `git config --global --add safe.directory "<cwd>" && ` so it succeeds immediately.
        If the user asks about a repository or service and the current directory is not confirmed to be inside it, write a command that checks the current directory first or locates it cleanly instead of assuming.
        """
        var userLines = ["Request: \(Redactor.redact(prompt))"]
        if let sysJSON = context.systemProfileJSON, !sysJSON.isEmpty {
            userLines.append("System Profile (JSON): \(sysJSON)")
        }
        if let cwd = context.workingDirectory { userLines.append("Directory: \(cwd)") }
        if let last = context.lastCommand { userLines.append("Previous command: \(Redactor.redact(last))") }
        if !screenSlice.text.isEmpty {
            userLines.append("Recent screen lines:\n\(screenSlice.text)")
        }
        let userPrompt = userLines.joined(separator: "\n")

        let response = try await client.complete(
            system: system,
            user: userPrompt,
            settings: cfg,
            apiKey: loadAPIKey(for: cfg.provider)
        )
        ledger.record(response.usage)
        audit.record(AuditRecord(actor: "onboard-ai:\(cfg.provider.rawValue)", action: "draft_command", target: context.hostLabel ?? "local", detail: "\(response.usage.totalTokens) tokens", outcome: .allowed))
        return Self.parseStructured(response.text, usage: response.usage, truncatedLines: screenSlice.omittedLines)
    }

    /// Automatically repairs a suggested command after the local screen watcher sees it fail.
    public func repairCommand(
        originalPrompt: String,
        failedCommand: String,
        failureOutput: String,
        context: AssistContext
    ) async throws -> AssistResult {
        let cfg = config
        guard cfg.enabled else { throw AssistError.disabled }

        // Fast zero-token path for well-known CLI friction points (e.g. Git dubious ownership / safe.directory).
        if let builtIn = ContextBudgeter.extractBuiltInRemedy(output: failureOutput, failedCommand: failedCommand) {
            log.info("auto-repaired failed suggestion via built-in rule (0 tokens)")
            return builtIn
        }

        let slice = ContextBudgeter.prepare(failureOutput, maxTokens: min(cfg.maxContextTokens, 350))
        let system = """
        You are Harbor's built-in terminal self-correction assistant.
        A command you suggested failed when executed in the user's terminal.
        Inspect the `System Profile (JSON)` and terminal output lines below, explain in plain, accessible language why it failed (especially if a directory is untrusted like Git's `safe.directory`, a flag is missing, or the user is in the wrong directory), and provide a single corrected shell command (chaining prerequisites with `&&` if needed) so the user doesn't have to piece together manual steps.
        Respond strictly in this two-part format:
        COMMAND: <corrected single-line shell command>
        EXPLANATION: <concise, plain-English reason it failed and how this command fixes it>
        Target shell: \(context.shell). Environment: \(context.isRemote ? "Remote SSH (\(context.hostLabel ?? "server"))" : "macOS").
        """
        var userLines: [String] = []
        if !originalPrompt.isEmpty {
            userLines.append("Original goal: \(Redactor.redact(originalPrompt))")
        }
        if let sysJSON = context.systemProfileJSON, !sysJSON.isEmpty {
            userLines.append("System Profile (JSON): \(sysJSON)")
        }
        userLines.append("Failed command: \(Redactor.redact(failedCommand))")
        if let code = context.lastExitCode {
            userLines.append("Exit code: \(code)")
        }
        if let cwd = context.workingDirectory {
            userLines.append("Directory: \(cwd)")
        }
        userLines.append("Terminal output:\n\(slice.text)")

        let response = try await client.complete(
            system: system,
            user: userLines.joined(separator: "\n"),
            settings: cfg,
            apiKey: loadAPIKey(for: cfg.provider)
        )
        ledger.record(response.usage)
        log.info("auto-repaired failed suggestion (\(response.usage.totalTokens) tokens)")
        audit.record(AuditRecord(actor: "onboard-ai:\(cfg.provider.rawValue)", action: "repair_command", target: context.hostLabel ?? "local", detail: "\(response.usage.totalTokens) tokens", outcome: .allowed))
        return Self.parseStructured(response.text, usage: response.usage, truncatedLines: slice.omittedLines)
    }

    /// Explains why a command or SSH session failed and suggests a fix command if applicable.
    public func explainFailure(context: AssistContext) async throws -> AssistResult {
        let cfg = config
        guard cfg.enabled else { throw AssistError.disabled }
        if let cmd = context.lastCommand,
           let builtIn = ContextBudgeter.extractBuiltInRemedy(output: context.rawOutput, failedCommand: cmd) {
            return builtIn
        }
        let slice = ContextBudgeter.prepare(context.rawOutput, maxTokens: cfg.maxContextTokens)
        let system = """
        You are Harbor's built-in terminal diagnostics assistant. Be concise (2-3 sentences max).
        If a shell command will fix or inspect the problem, include a line starting with:
        COMMAND: <single-line command>
        Followed by:
        EXPLANATION: <concise root cause and why the fix works>
        """
        var userLines: [String] = []
        if let sysJSON = context.systemProfileJSON, !sysJSON.isEmpty {
            userLines.append("System Profile (JSON): \(sysJSON)")
        }
        if let cmd = context.lastCommand { userLines.append("Command: \(Redactor.redact(cmd))") }
        if let code = context.lastExitCode { userLines.append("Exit code: \(code)") }
        if let cwd = context.workingDirectory { userLines.append("Directory: \(cwd)") }
        userLines.append("Output:\n\(slice.text)")

        let response = try await client.complete(
            system: system,
            user: userLines.joined(separator: "\n"),
            settings: cfg,
            apiKey: loadAPIKey(for: cfg.provider)
        )
        ledger.record(response.usage)
        log.info("explained failure (\(response.usage.totalTokens) tokens)")
        audit.record(AuditRecord(actor: "onboard-ai:\(cfg.provider.rawValue)", action: "explain_failure", target: context.hostLabel ?? "local", detail: "\(response.usage.totalTokens) tokens", outcome: .allowed))
        return Self.parseStructured(response.text, usage: response.usage, truncatedLines: slice.omittedLines)
    }

    /// Parses and explains selected terminal lines or log entries.
    public func explainLogSelection(_ selection: String, context: AssistContext? = nil) async throws -> AssistResult {
        let cfg = config
        guard cfg.enabled else { throw AssistError.disabled }
        let slice = ContextBudgeter.prepare(selection, maxTokens: cfg.maxContextTokens)
        let system = """
        You are Harbor's log and terminal output analyzer. Summarize what the log/output means, highlight any errors or anomalies in 2-3 concise sentences, and optionally include `COMMAND: <command>` if a follow-up command is helpful.
        """
        var userText = slice.text
        if let sysJSON = context?.systemProfileJSON, !sysJSON.isEmpty {
            userText = "System Profile (JSON): \(sysJSON)\n\(slice.text)"
        }
        let response = try await client.complete(
            system: system,
            user: userText,
            settings: cfg,
            apiKey: loadAPIKey(for: cfg.provider)
        )
        ledger.record(response.usage)
        audit.record(AuditRecord(actor: "onboard-ai:\(cfg.provider.rawValue)", action: "explain_logs", target: context?.hostLabel ?? "logs", detail: "\(response.usage.totalTokens) tokens", outcome: .allowed))
        return Self.parseStructured(response.text, usage: response.usage, truncatedLines: slice.omittedLines)
    }

    /// Proposes the next logical shell command based on the recent command and its output.
    public func suggestContinuation(context: AssistContext) async throws -> AssistResult {
        let cfg = config
        guard cfg.enabled else { throw AssistError.disabled }
        let slice = ContextBudgeter.prepare(context.rawOutput, maxTokens: min(cfg.maxContextTokens, 1_000))
        let system = """
        You are Harbor's intelligent continuation assistant. Based on the system profile, last command, and its output, suggest the single most useful next shell command.
        Respond strictly with:
        COMMAND: <next shell command>
        EXPLANATION: <one short sentence explaining why>
        """
        var userLines: [String] = []
        if let sysJSON = context.systemProfileJSON, !sysJSON.isEmpty {
            userLines.append("System Profile (JSON): \(sysJSON)")
        }
        if let cmd = context.lastCommand { userLines.append("Last command: \(Redactor.redact(cmd))") }
        if let code = context.lastExitCode { userLines.append("Exit status: \(code)") }
        if !slice.text.isEmpty { userLines.append("Output:\n\(slice.text)") }

        let response = try await client.complete(
            system: system,
            user: userLines.joined(separator: "\n"),
            settings: cfg,
            apiKey: loadAPIKey(for: cfg.provider)
        )
        ledger.record(response.usage)
        audit.record(AuditRecord(actor: "onboard-ai:\(cfg.provider.rawValue)", action: "suggest_continuation", target: context.hostLabel ?? "local", detail: "\(response.usage.totalTokens) tokens", outcome: .allowed))
        return Self.parseStructured(response.text, usage: response.usage, truncatedLines: slice.omittedLines)
    }

    /// Summarizes a background command failure in one short sentence for a macOS notification.
    public func summarizeForAlert(context: AssistContext) async throws -> String {
        let cfg = config
        guard cfg.enabled, cfg.smartBackgroundAlerts else { throw AssistError.disabled }
        let slice = ContextBudgeter.prepare(context.rawOutput, maxTokens: min(cfg.maxContextTokens, 600))
        var smallSettings = cfg
        smallSettings.maxOutputTokens = 80
        let response = try await client.complete(
            system: "Summarize why this command failed in one short sentence (under 18 words) suitable for a desktop notification.",
            user: "Command: \(Redactor.redact(context.lastCommand ?? "command"))\nExit: \(context.lastExitCode ?? 1)\n\(slice.text)",
            settings: smallSettings,
            apiKey: loadAPIKey(for: cfg.provider)
        )
        ledger.record(response.usage)
        return response.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Parsing & Sanitization

    public nonisolated static func parseStructured(_ text: String, usage: TokenUsage, truncatedLines: Int) -> AssistResult {
        var command: String?
        var explanationLines: [String] = []

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "**COMMAND:**", with: "COMMAND:", options: .caseInsensitive)
                .replacingOccurrences(of: "`COMMAND:`", with: "COMMAND:", options: .caseInsensitive)
            if line.uppercased().hasPrefix("COMMAND:") {
                let rawExtracted = line.dropFirst("COMMAND:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                let extracted = sanitizeCommand(rawExtracted)
                if !extracted.isEmpty, extracted.lowercased() != "none", extracted.lowercased() != "n/a" {
                    command = extracted
                }
            } else if line.uppercased().hasPrefix("EXPLANATION:") {
                let extracted = line.dropFirst("EXPLANATION:".count).trimmingCharacters(in: .whitespaces)
                if !extracted.isEmpty { explanationLines.append(extracted) }
            } else if !line.hasPrefix("```") {
                explanationLines.append(rawLine)
            }
        }

        let explanation = explanationLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return AssistResult(
            explanation: explanation.isEmpty ? text : explanation,
            suggestedCommand: command,
            usage: usage,
            truncatedLines: truncatedLines
        )
    }

    /// Cleans up common LLM formatting quirks (stuttered `C` from `COMMAND:`, leading prompt
    /// symbols like `$ `, or misplaced `C git` prefixes) before staging into the shell.
    public nonisolated static func sanitizeCommand(_ raw: String) -> String {
        var cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            .trimmingCharacters(in: .whitespaces)

        while cleaned.uppercased().hasPrefix("COMMAND:") {
            cleaned = String(cleaned.dropFirst("COMMAND:".count)).trimmingCharacters(in: .whitespaces)
        }
        for promptPrefix in ["$ ", "# ", "% ", "❯ "] {
            if cleaned.hasPrefix(promptPrefix) {
                cleaned = String(cleaned.dropFirst(promptPrefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }

        let commonTools = [
            "git", "ls", "cd", "cat", "grep", "rg", "find", "docker", "kubectl",
            "systemctl", "journalctl", "apt", "apt-get", "dnf", "yum", "brew",
            "ssh", "scp", "rsync", "tar", "curl", "wget", "python", "python3",
            "npm", "pnpm", "cargo", "make", "swift", "sudo", "ps", "df", "du",
            "top", "htop", "tail", "head", "chmod", "chown", "pwd", "echo"
        ]
        for tool in commonTools {
            if cleaned == "C\(tool)" || cleaned.hasPrefix("C\(tool) ") {
                cleaned = String(cleaned.dropFirst())
                break
            }
            if cleaned == "C \(tool)" || cleaned.hasPrefix("C \(tool) ") {
                cleaned = String(cleaned.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        return cleaned
    }
}
