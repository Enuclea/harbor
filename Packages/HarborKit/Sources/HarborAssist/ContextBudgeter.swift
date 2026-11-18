import Foundation
import HarborCore
import HarborLogging

/// Prepares terminal output or logs for an LLM within a strict token budget:
/// strips ANSI escapes, redacts secrets, collapses consecutive duplicate lines,
/// and keeps head + tail lines when the slice exceeds `maxTokens`.
public enum ContextBudgeter {
    public struct BudgetedSlice: Sendable, Equatable {
        public let text: String
        public let estimatedTokens: Int
        public let omittedLines: Int

        public init(text: String, estimatedTokens: Int, omittedLines: Int) {
            self.text = text
            self.estimatedTokens = estimatedTokens
            self.omittedLines = omittedLines
        }
    }

    /// Fast, deterministic token estimate (~4 UTF-8 bytes per token for code/logs).
    public static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, (text.utf8.count + 3) / 4)
    }

    /// Strips ANSI control sequences, redacts credentials/keys, deduplicates repeated lines,
    /// and truncates middle lines so the output fits within `maxTokens`.
    public static func prepare(_ raw: String, maxTokens: Int) -> BudgetedSlice {
        let stripped = ANSIStripper.plainText(from: Data(raw.utf8))
        let redacted = Redactor.redact(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !redacted.isEmpty else {
            return BudgetedSlice(text: "", estimatedTokens: 0, omittedLines: 0)
        }

        let deduplicated = collapseRepeatedLines(redacted.components(separatedBy: "\n"))
        let joined = deduplicated.joined(separator: "\n")
        let budget = max(64, maxTokens)
        let fullTokens = estimateTokens(joined)
        guard fullTokens > budget else {
            return BudgetedSlice(text: joined, estimatedTokens: fullTokens, omittedLines: 0)
        }

        // Allocate ~30% to the head (command & initial error) and ~70% to the tail (final traceback/exit).
        let maxChars = budget * 4
        let headBudget = max(80, Int(Double(maxChars) * 0.30))
        let tailBudget = max(120, maxChars - headBudget - 64)

        var headLines: [String] = []
        var headChars = 0
        for line in deduplicated {
            let clipped = line.count > 400 ? String(line.prefix(400)) + "…" : line
            if headChars + clipped.count + 1 > headBudget, !headLines.isEmpty { break }
            headLines.append(clipped)
            headChars += clipped.count + 1
        }

        var tailLines: [String] = []
        var tailChars = 0
        for line in deduplicated.dropFirst(headLines.count).reversed() {
            let clipped = line.count > 400 ? String(line.prefix(400)) + "…" : line
            if tailChars + clipped.count + 1 > tailBudget, !tailLines.isEmpty { break }
            tailLines.append(clipped)
            tailChars += clipped.count + 1
        }
        tailLines.reverse()

        let omitted = max(0, deduplicated.count - headLines.count - tailLines.count)
        let marker = "[… \(omitted) lines omitted to stay within \(budget)-token budget …]"
        let combined = (headLines + [marker] + tailLines).joined(separator: "\n")
        return BudgetedSlice(
            text: combined,
            estimatedTokens: estimateTokens(combined),
            omittedLines: omitted
        )
    }

    /// Extracts only the output of the most recent command from a raw PTY replay buffer
    /// using OSC 133 marks if present, falling back to the last 80 lines.
    public static func extractLastCommandOutput(from replay: Data) -> String {
        let marker = Data("\u{1B}]133;C".utf8)
        if let lastStart = replay.range(of: marker, options: .backwards) {
            let slice = replay[lastStart.upperBound...]
            let bodyStart = slice.firstIndex(where: { $0 == 0x07 || $0 == 0x5C }).map { $0 + 1 } ?? lastStart.upperBound
            var region = Data(replay[bodyStart...])
            if let endRange = region.range(of: Data("\u{1B}]133;D".utf8)) {
                region = region.prefix(upTo: endRange.lowerBound)
            }
            return ANSIStripper.plainText(from: region).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let plain = ANSIStripper.plainText(from: replay.suffix(16_384))
        let lines = plain.components(separatedBy: "\n")
        return lines.suffix(80).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts plain-text terminal output appended to `replay` after `offset`.
    public static func extractOutputSince(offset: Int, in replay: Data) -> String {
        guard offset < replay.count else { return "" }
        let slice = replay.subdata(in: max(0, offset)..<replay.count)
        return ANSIStripper.plainText(from: slice).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Zero-token local check over the few lines printed after running a suggested command.
    /// Returns a short failure reason if either `exitCode` is non-zero or the screen lines
    /// contain a standard shell/CLI error signature; returns `nil` if the command succeeded.
    public static func detectCommandFailure(output: String, command: String?, exitCode: Int32?) -> String? {
        let lines = output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let cleanedLines = lines.filter { line in
            if let cmd = command?.trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty {
                if line == cmd || line.hasSuffix("$ " + cmd) || line.hasSuffix("# " + cmd) || line.hasSuffix("% " + cmd) || line.hasSuffix("❯ " + cmd) {
                    return false
                }
            }
            return !looksLikePromptLine(line)
        }

        if let code = exitCode, code != 0, code != 130 {
            return cleanedLines.first ?? "Exited with status \(code)"
        }

        let failurePatterns = [
            "command not found",
            ": not found",
            "no such file or directory",
            "not a git repository",
            "dubious ownership",
            "safe.directory",
            "fatal:",
            "error:",
            "e: unable to",
            "e: could not",
            "permission denied",
            "operation not permitted",
            "invalid option",
            "unknown option",
            "unrecognized option",
            "illegal option",
            "syntax error",
            "cannot access",
            "cannot open",
            "failed to ",
            "does not exist",
            "unknown command"
        ]

        for line in cleanedLines.prefix(25) {
            let lower = line.lowercased()
            if failurePatterns.contains(where: { lower.contains($0) }) {
                return line
            }
        }
        return nil
    }

    /// Zero-token instant remedy extractor for well-known CLI friction points (such as Git's
    /// `dubious ownership` / `safe.directory` prompt or a stuttered command prefix).
    /// Returns `nil` when an LLM repair pass should be used instead.
    public static func extractBuiltInRemedy(output: String, failedCommand: String) -> AssistResult? {
        let lines = output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // 1. Git dubious ownership / safe.directory prompt
        if output.localizedCaseInsensitiveContains("dubious ownership") || output.localizedCaseInsensitiveContains("safe.directory") {
            if let safeDirLine = lines.first(where: { $0.hasPrefix("git config --global --add safe.directory ") }) {
                let chained = "\(safeDirLine) && \(failedCommand)"
                return AssistResult(
                    explanation: "Git blocked this command because the repository folder is owned by a different user on this system. Running the command below marks this directory as trusted (`safe.directory`) and then runs `\(failedCommand)`.",
                    suggestedCommand: chained,
                    usage: TokenUsage(inputTokens: 0, outputTokens: 0),
                    truncatedLines: 0
                )
            }
        }

        // 2. Stuttered leading 'C' on a standard command (e.g. `Cgit: command not found`)
        let sanitized = AssistService.sanitizeCommand(failedCommand)
        if sanitized != failedCommand,
           output.localizedCaseInsensitiveContains("not found") {
            return AssistResult(
                explanation: "The previous command had a leading typo (`\(failedCommand)`). Corrected to `\(sanitized)`.",
                suggestedCommand: sanitized,
                usage: TokenUsage(inputTokens: 0, outputTokens: 0),
                truncatedLines: 0
            )
        }

        return nil
    }

    /// Heuristic for whether a terminal line is an interactive shell prompt (for hosts without OSC 133).
    public static func looksLikePromptLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count < 120 else { return false }
        if let last = trimmed.last, ["$", "#", "%", "❯"].contains(last) {
            return true
        }
        return false
    }

    private static func collapseRepeatedLines(_ lines: [String]) -> [String] {
        var result: [String] = []
        var previous: String?
        var count = 0

        func flushRepeats() {
            if count > 1 {
                result.append("  [repeated \(count) times]")
            }
            count = 0
        }

        for line in lines {
            let trimmedRight = line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            if trimmedRight == previous, !trimmedRight.isEmpty {
                count += 1
            } else {
                flushRepeats()
                result.append(trimmedRight)
                previous = trimmedRight
                count = 1
            }
        }
        flushRepeats()
        return result
    }
}
