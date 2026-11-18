import AppKit
import HarborAssist
import HarborCore
import HarborFiles
import HarborHostSetup
import HarborSessions
import HarborSSH
import Observation
import SwiftUI

/// Coordinates inline Onboard AI requests (`⌘I` command drafting, failure explanation,
/// selection analysis, intelligent continuation, and post-execution screen verification)
/// for one terminal tab.
@MainActor
@Observable
final class CommandAssistModel {
    enum WatchState: Equatable {
        case idle
        case awaitingEnter(command: String)
        case watching(command: String)
        case verified(command: String)
        case repairing(command: String, reason: String)
    }

    var isVisible = false
    var prompt = ""
    var isWorking = false
    var result: AssistResult?
    var errorMessage: String?
    var watchState: WatchState = .idle
    var wasAutoRepaired = false
    var activePlaybookSheet: ScriptPlaybook?

    @ObservationIgnored private let session: TerminalSession
    @ObservationIgnored let services: AppServices
    @ObservationIgnored private var lastSubmittedPrompt = ""
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored var onStageCommand: @MainActor (String) -> Void = { _ in }
    @ObservationIgnored var onRunCommand: @MainActor (String) -> Void = { _ in }
    @ObservationIgnored var onDismiss: @MainActor () -> Void = {}

    init(session: TerminalSession, services: AppServices) {
        self.session = session
        self.services = services
    }

    var isEnabled: Bool {
        services.settings.settings.ai.onboard.enabled
    }

    var systemProfile: SystemProfile? {
        session.systemProfile
    }

    var systemProfileJSON: String? {
        session.systemProfile?.compactJSON(cwd: session.workingDirectory)
    }

    var estimatedPromptTokens: Int {
        let screenTokens = min(240, ContextBudgeter.estimateTokens(recentScreenTail()))
        let sysTokens = systemProfileJSON.map(ContextBudgeter.estimateTokens) ?? 35
        return ContextBudgeter.estimateTokens(prompt) + screenTokens + sysTokens + 75
    }

    var estimatedFailureTokens: Int {
        let output = ContextBudgeter.extractLastCommandOutput(from: session.pipeline.replay)
        let budget = services.settings.settings.ai.onboard.maxContextTokens
        return ContextBudgeter.prepare(output, maxTokens: budget).estimatedTokens + 70
    }

    func toggle() {
        isVisible.toggle()
        if isVisible {
            Task { await ensureSystemProfile() }
        } else {
            onDismiss()
        }
    }

    func submitPrompt() async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWorking else { return }
        watchTask?.cancel()
        watchState = .idle
        wasAutoRepaired = false
        lastSubmittedPrompt = trimmed
        isWorking = true
        errorMessage = nil
        await ensureSystemProfile()
        do {
            result = try await services.assist.draftCommand(
                prompt: trimmed,
                context: makeContext(includeOutput: true, screenTailOnly: true)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    func explainLastFailure() async {
        watchTask?.cancel()
        watchState = .idle
        wasAutoRepaired = false
        isVisible = true
        isWorking = true
        errorMessage = nil
        do {
            result = try await services.assist.explainFailure(context: makeContext(includeOutput: true))
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    func explainSelection(_ text: String) async {
        watchTask?.cancel()
        watchState = .idle
        wasAutoRepaired = false
        isVisible = true
        isWorking = true
        errorMessage = nil
        do {
            result = try await services.assist.explainLogSelection(text, context: makeContext(includeOutput: false))
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    func suggestNextStep() async {
        watchTask?.cancel()
        watchState = .idle
        wasAutoRepaired = false
        isVisible = true
        isWorking = true
        errorMessage = nil
        do {
            result = try await services.assist.suggestContinuation(context: makeContext(includeOutput: true))
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    func stage(_ command: String) {
        onStageCommand(command)
        isVisible = false
        onDismiss()
        startWatching(command: command, executedImmediately: false)
    }

    func runAndWatch(_ command: String) {
        onRunCommand(command)
        onDismiss()
        startWatching(command: command, executedImmediately: true)
    }

    func openAISettings() {
        services.actions?.openSettings(section: .assistants)
    }

    func openGitHubSettings() {
        services.actions?.openSettings(section: .github)
    }

    /// Stages or executes a checked-in GitHub script on the active tab (uploading over shared SSH
    /// for remote hosts, or running from the local checkout for local shells).
    func executePlaybook(_ playbook: ScriptPlaybook, variables: [String: String], executeImmediately: Bool) async {
        lastSubmittedPrompt = "Run GitHub script \(playbook.name) (\(playbook.relativePath))"
        if session.kind == .localShell {
            let cmd = ScriptPlaybook.buildCommand(
                scriptPath: playbook.fileURL.path,
                interpreter: playbook.interpreter,
                requiresSudo: playbook.requiresSudo,
                variables: playbook.variables,
                values: variables,
                cleanupAfter: false
            )
            if executeImmediately {
                runAndWatch(cmd)
            } else {
                stage(cmd)
            }
            return
        }

        guard let host = session.kind.host,
              let contents = try? Data(contentsOf: playbook.fileURL) else { return }
        let safeSlug = playbook.fileURL.lastPathComponent.replacingOccurrences(of: " ", with: "-")
        let remoteTempPath = "/tmp/harbor-playbook-\(safeSlug)"

        let sshSettings = services.settings.settings.ssh
        let builder = SSHCommandBuilder(settings: sshSettings, controlDirectory: services.paths.sshControl)
        let browser = RemoteFileBrowser.ssh(host: host, builder: builder)

        do {
            try await browser.writeFile(remoteTempPath, contents: contents, permissions: 0o700)
            let cmd = ScriptPlaybook.buildCommand(
                scriptPath: remoteTempPath,
                interpreter: playbook.interpreter,
                requiresSudo: playbook.requiresSudo,
                variables: playbook.variables,
                values: variables,
                cleanupAfter: executeImmediately
            )
            if executeImmediately {
                runAndWatch(cmd)
            } else {
                stage(cmd)
            }
        } catch {
            // Fallback if shared SSH socket isn't ready: materialize via base64 in /tmp and execute
            let b64 = contents.base64EncodedString()
            let runner = ScriptPlaybook.buildCommand(
                scriptPath: remoteTempPath,
                interpreter: playbook.interpreter,
                requiresSudo: playbook.requiresSudo,
                variables: playbook.variables,
                values: variables,
                cleanupAfter: executeImmediately
            )
            let fallbackCmd = "printf '%s' '\(b64)' | base64 -d > '\(remoteTempPath)' && chmod 0700 '\(remoteTempPath)' && \(runner)"
            if executeImmediately {
                runAndWatch(fallbackCmd)
            } else {
                stage(fallbackCmd)
            }
        }
    }

    // MARK: Post-Execution Zero-Token Screen Watcher

    /// Watches the terminal output for a few lines after a suggested command is staged/run.
    /// Costs 0 tokens when the command succeeds; automatically invokes `repairCommand` if
    /// the command exits non-zero or prints an error signature.
    private func startWatching(command: String, executedImmediately: Bool) {
        watchTask?.cancel()
        let baselineOffset = session.pipeline.replay.count
        let baselineCommandStart = session.lastCommand?.startedAt
        let goal = lastSubmittedPrompt

        watchState = executedImmediately ? .watching(command: command) : .awaitingEnter(command: command)

        watchTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var executionOffset = baselineOffset
            if !executedImmediately {
                // Wait up to 25s for the user to press Return on the staged command.
                let enterDeadline = ContinuousClock.now + .seconds(25)
                var didPressEnter = false
                while ContinuousClock.now < enterDeadline, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(120))
                    if self.session.lastCommand?.startedAt != baselineCommandStart {
                        didPressEnter = true
                        break
                    }
                    let delta = ContextBudgeter.extractOutputSince(offset: baselineOffset, in: self.session.pipeline.replay)
                    if delta.contains("\n") {
                        didPressEnter = true
                        break
                    }
                }
                guard didPressEnter, !Task.isCancelled else {
                    self.watchState = .idle
                    return
                }
                executionOffset = baselineOffset
                self.watchState = .watching(command: command)
            }

            // Watch the next few lines of output for up to 8 seconds.
            let watchDeadline = ContinuousClock.now + .seconds(8)
            var lastObservedLength = self.session.pipeline.replay.count
            var lastChangeTime = ContinuousClock.now

            while ContinuousClock.now < watchDeadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                let currentLength = self.session.pipeline.replay.count
                if currentLength != lastObservedLength {
                    lastObservedLength = currentLength
                    lastChangeTime = .now
                }

                // 1. If OSC 133 shell integration reported command completion, we have an exact answer.
                if let lastCmd = self.session.lastCommand,
                   lastCmd.startedAt != baselineCommandStart,
                   lastCmd.finishedAt != nil {
                    let captured = ContextBudgeter.extractOutputSince(offset: executionOffset, in: self.session.pipeline.replay)
                    await self.evaluateWatchedOutput(captured, command: command, exitCode: lastCmd.exitCode, goal: goal)
                    return
                }

                // 2. For SSH hosts without shell integration, watch the screen lines until output settles.
                let captured = ContextBudgeter.extractOutputSince(offset: executionOffset, in: self.session.pipeline.replay)
                let lines = captured
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                guard !lines.isEmpty else { continue }
                let settled = (ContinuousClock.now - lastChangeTime) >= .milliseconds(450)
                if settled {
                    let hasFailure = ContextBudgeter.detectCommandFailure(output: captured, command: command, exitCode: nil) != nil
                    let backAtPrompt = lines.last.map(ContextBudgeter.looksLikePromptLine) == true && lines.count >= 2
                    if hasFailure || backAtPrompt {
                        await self.evaluateWatchedOutput(captured, command: command, exitCode: nil, goal: goal)
                        return
                    }
                }
            }

            // Final check at the end of the watch window.
            guard !Task.isCancelled else { return }
            let finalOutput = ContextBudgeter.extractOutputSince(offset: executionOffset, in: self.session.pipeline.replay)
            await self.evaluateWatchedOutput(finalOutput, command: command, exitCode: nil, goal: goal)
        }
    }

    private func evaluateWatchedOutput(_ output: String, command: String, exitCode: Int32?, goal: String) async {
        if let reason = ContextBudgeter.detectCommandFailure(output: output, command: command, exitCode: exitCode) {
            watchState = .repairing(command: command, reason: reason)
            isVisible = true
            isWorking = true
            errorMessage = nil
            do {
                var ctx = makeContext(includeOutput: false)
                ctx.lastCommand = command
                ctx.lastExitCode = exitCode
                result = try await services.assist.repairCommand(
                    originalPrompt: goal,
                    failedCommand: command,
                    failureOutput: output,
                    context: ctx
                )
                wasAutoRepaired = true
                watchState = .idle
            } catch {
                errorMessage = error.localizedDescription
                watchState = .idle
            }
            isWorking = false
        } else {
            watchState = .verified(command: command)
            try? await Task.sleep(for: .milliseconds(1_400))
            if case .verified = watchState {
                watchState = .idle
                if isVisible && !isWorking {
                    isVisible = false
                }
            }
        }
    }

    // MARK: Context Builder

    private func recentScreenTail() -> String {
        var lines: [String] = []
        if let snapshot = session.screen?.screenSnapshot(scrollbackLines: 0) {
            lines = snapshot.lines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .suffix(15)
        } else {
            let raw = ContextBudgeter.extractLastCommandOutput(from: session.pipeline.replay)
            lines = raw.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .suffix(15)
        }

        // For local shells, add a zero-cost directory summary (whether .git exists and top-level entries).
        if session.kind == .localShell, let cwd = session.workingDirectory {
            let fm = FileManager.default
            let isGit = fm.fileExists(atPath: (cwd as NSString).appendingPathComponent(".git"))
            if let entries = try? fm.contentsOfDirectory(atPath: cwd) {
                let sample = entries.filter { !$0.hasPrefix(".") }.sorted().prefix(12).joined(separator: ", ")
                lines.append("[Local cwd: git=\(isGit), entries: \(sample)]")
            }
        }
        if let scriptsSummary = services.githubScripts.assistContextSummary {
            lines.append("[Checked-in GitHub Playbooks:\n\(scriptsSummary)]")
        }
        return lines.joined(separator: "\n")
    }

    private func ensureSystemProfile() async {
        if session.kind == .localShell {
            var local = session.systemProfile ?? .currentLocal(shell: session.shellIntegration, cwd: session.workingDirectory)
            local.cwd = session.workingDirectory
            session.systemProfile = local
            return
        }
        guard session.systemProfile == nil, let host = session.kind.host else { return }
        let sshSettings = services.settings.settings.ssh
        let controlDir = services.paths.sshControl
        let executor = SSHCommandBuilder(settings: sshSettings, controlDirectory: controlDir).executor(for: host)
        if let result = try? await executor(SystemProfile.remoteProbeCommand),
           result.succeeded,
           var profile = SystemProfile.decode(from: result.output) {
            if let cwd = session.workingDirectory { profile.cwd = cwd }
            session.systemProfile = profile
        }
    }

    private func makeContext(includeOutput: Bool, screenTailOnly: Bool = false) -> AssistContext {
        let output: String
        if !includeOutput {
            output = ""
        } else if screenTailOnly {
            output = recentScreenTail()
        } else {
            output = ContextBudgeter.extractLastCommandOutput(from: session.pipeline.replay)
        }
        return AssistContext(
            shell: session.shellIntegration ?? session.systemProfile?.shell ?? (session.kind.host != nil ? "bash/sh" : "zsh"),
            isRemote: session.kind.host != nil,
            hostLabel: session.kind.host?.destinationLabel,
            workingDirectory: session.workingDirectory ?? session.systemProfile?.cwd,
            lastCommand: session.lastCommandLine,
            lastExitCode: session.lastCommand?.exitCode,
            systemProfileJSON: systemProfileJSON,
            rawOutput: output
        )
    }
}

/// Floating bar for `⌘I` Onboard AI Assist: natural language command drafting,
/// failure analysis, 1-click staging, and zero-token post-execution screen verification.
struct CommandAssistBar: View {
    @Bindable var model: CommandAssistModel
    @FocusState private var focused: Bool

    var body: some View {
        if model.isVisible {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                        .font(.callout.weight(.semibold))
                    TextField("Ask AI to draft a command (e.g. “check repo status” or “find files > 100MB”)…", text: $model.prompt)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .focused($focused)
                        .onSubmit {
                            if let cmd = model.result?.suggestedCommand, model.prompt.isEmpty {
                                model.stage(cmd)
                            } else {
                                Task { await model.submitPrompt() }
                            }
                        }

                    if let profile = model.systemProfile, let json = model.systemProfileJSON {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(json, forType: .string)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "cpu")
                                Text(profile.badgeSummary)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("System Profile JSON fed to AI (click to copy):\n\(json)")
                    }

                    Text("~\(model.estimatedPromptTokens) tok")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .help("Estimated input tokens (includes System Profile JSON + last 15 screen lines)")

                    if model.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Draft") { Task { await model.submitPrompt() } }
                            .controlSize(.small)
                            .disabled(model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Next Step") { Task { await model.suggestNextStep() } }
                            .controlSize(.small)
                            .help("Suggest the next command from recent terminal output")
                        scriptsMenu
                    }

                    Button {
                        model.isVisible = false
                        model.onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Close (Esc)")
                }

                watchStatusBanner

                if let error = model.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Configure AI…") { model.openAISettings() }
                            .controlSize(.small)
                    }
                }

                if let result = model.result {
                    Divider().opacity(0.4)
                    VStack(alignment: .leading, spacing: 8) {
                        if model.wasAutoRepaired {
                            Label("Auto-corrected from terminal output", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }

                        Text(result.explanation)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)

                        if let cmd = result.suggestedCommand {
                            HStack(spacing: 8) {
                                Text(cmd)
                                    .font(.system(.callout, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                                    .textSelection(.enabled)

                                Button("Stage in Prompt") { model.stage(cmd) }
                                    .controlSize(.small)
                                    .help("Paste into the terminal prompt without pressing Return (watches output when you run it)")

                                Button("Run & Watch") { model.runAndWatch(cmd) }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .help("Run in terminal and watch the next few screen lines to verify it worked")

                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(cmd, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help("Copy command")
                            }
                        }

                        HStack {
                            Text("Used \(result.usage.totalTokens) tokens (\(result.usage.inputTokens) in / \(result.usage.outputTokens) out)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            if result.truncatedLines > 0 {
                                Text("· \(result.truncatedLines) middle lines omitted for budget")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 680)
            .glassPanel(cornerRadius: 14)
            .onAppear { focused = true }
            .onKeyPress(.escape) {
                model.isVisible = false
                model.onDismiss()
                return .handled
            }
            .sheet(item: $model.activePlaybookSheet) { playbook in
                PlaybookRunnerSheet(playbook: playbook, store: model.services.settings, services: model.services) {
                    model.activePlaybookSheet = nil
                }
            }
        }
    }

    private var scriptsMenu: some View {
        Menu {
            let scripts = model.services.githubScripts.scripts
            if scripts.isEmpty {
                Button("Load Starter Security Scripts") {
                    try? model.services.githubScripts.seedStarterTemplates()
                }
            } else {
                ForEach(scripts) { script in
                    Button("\(script.name) (\(script.relativePath))") {
                        model.activePlaybookSheet = script
                    }
                }
                Divider()
                if !model.services.settings.settings.github.repositoryURL.isEmpty {
                    Button("Pull Latest from GitHub") {
                        Task { _ = try? await model.services.githubScripts.sync() }
                    }
                }
            }
            Divider()
            Button("GitHub Scripts Settings…") {
                model.openGitHubSettings()
            }
        } label: {
            Label("Scripts", systemImage: "arrow.triangle.branch")
        }
        .controlSize(.small)
        .help("Pull or run pre-canned parameterized scripts from your GitHub repository")
    }

    @ViewBuilder
    private var watchStatusBanner: some View {
        switch model.watchState {
        case .idle:
            EmptyView()
        case .awaitingEnter(let cmd):
            HStack(spacing: 6) {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                Text("Staged `\(cmd)` — press Return in terminal; AI will watch output for errors (0 tokens if ok).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .watching(let cmd):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Watching screen output for `\(cmd)`…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .verified(let cmd):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("`\(cmd)` ran cleanly (0 extra tokens).")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
        case .repairing(_, let reason):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Command failed (\(reason)) — drafting fix from screen output…")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
