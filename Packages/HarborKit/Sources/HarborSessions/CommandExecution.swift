import Foundation
import HarborControl
import HarborCore

extension TerminalSession {
    /// Types `command`, presses Return and collects its output.
    ///
    /// With shell integration the output is exactly what was printed between the
    /// command-start and command-end marks, and the exit code is real. Without it,
    /// Harbor waits for output to go quiet and returns a best-effort transcript.
    func run(_ command: String, timeout: Duration) async -> CommandOutcome {
        let started = ContinuousClock.now
        let capture = pipeline.beginCapture()
        defer { pipeline.endCapture(capture) }

        var exitCode: Int32?
        var completed = false
        let usesMarks = shellIntegration != nil
        if usesMarks {
            let result = await waitForCommandCompletion(timeout: timeout) { send(text: command + "\r") }
            if case .finished(let code) = result {
                exitCode = code
                completed = true
                _ = await waitUntilAtPrompt(timeout: .milliseconds(750))
            }
        } else {
            send(text: command + "\r")
            completed = await waitForQuietOutput(idle: .milliseconds(800), timeout: timeout)
        }

        let raw = pipeline.capturedData(capture)
        let (output, truncated) = CommandOutputExtractor.extract(raw, command: command, usesMarks: usesMarks)
        let elapsed = ContinuousClock.now - started
        return CommandOutcome(
            output: output, exitCode: exitCode, completed: completed, truncated: truncated,
            durationMilliseconds: Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
    }

    /// Returns true once no output has arrived for `idle`, false on timeout.
    private func waitForQuietOutput(idle: Duration, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        try? await Task.sleep(for: .milliseconds(150))
        while ContinuousClock.now < deadline {
            let last = pipeline.lastOutputAt ?? .now
            if ContinuousClock.now - last >= idle { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}

/// Turns captured PTY bytes into the plain text an assistant should see.
enum CommandOutputExtractor {
    static let maximumCharacters = 32_000

    static func extract(_ raw: Data, command: String, usesMarks: Bool) -> (String, truncated: Bool) {
        var region = raw
        if usesMarks, let start = range(of: "\u{1B}]133;C", in: raw) {
            let afterStart = raw[start.upperBound...]
            // Skip the mark's terminator (BEL or ST).
            let bodyStart = afterStart.firstIndex(where: { $0 == 0x07 || $0 == 0x5C }).map { $0 + 1 } ?? start.upperBound
            let body = raw[bodyStart...]
            if let end = range(of: "\u{1B}]133;D", in: Data(body)) {
                region = Data(body).prefix(upTo: end.lowerBound)
            } else {
                region = Data(body)
            }
        }
        var text = ANSIStripper.plainText(from: region)
        if !usesMarks { text = dropEchoAndPrompt(text, command: command) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maximumCharacters else { return (text, false) }
        let omitted = text.count - maximumCharacters
        return ("[… \(omitted) earlier characters omitted …]\n" + String(text.suffix(maximumCharacters)), true)
    }

    /// Without marks the capture starts with the echoed command and ends with a new prompt.
    private static func dropEchoAndPrompt(_ text: String, command: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.contains(command.prefix(40)) { lines.removeFirst() }
        if lines.count > 1 { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func range(of marker: String, in data: Data) -> Range<Data.Index>? {
        data.range(of: Data(marker.utf8))
    }
}
