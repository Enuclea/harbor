import Foundation
import HarborCore

public enum ExpectError: Error, LocalizedError {
    case timedOut(pattern: String, transcript: String)
    case exited(TerminationStatus, transcript: String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let pattern, _): "Timed out waiting for “\(pattern)”"
        case .exited(let status, let transcript):
            "The program \(status): \(transcript.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))"
        }
    }

    public var transcript: String {
        switch self {
        case .timedOut(_, let transcript), .exited(_, let transcript): transcript
        }
    }
}

/// Drives an interactive program under a PTY, `expect`-style.
///
/// Used for tools that only accept secrets interactively (`ssh-keygen`, `ssh-add`) so
/// passphrases never appear in argv, where any local process could read them.
public actor ExpectSession {
    private enum Event: Sendable {
        case output(Data)
        case exited(TerminationStatus)
    }

    private var process: PTYProcess?
    private var pump: Task<Void, Never>?
    private var transcript = ""
    /// UTF-16 offset of the end of the previous match.
    private var consumedOffset = 0
    private var exitStatus: TerminationStatus?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public static func launch(
        executable: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ExpectSession {
        let session = ExpectSession()
        try await session.start(executable: executable, arguments: arguments, environment: environment)
        return session
    }

    private init() {}

    private func start(executable: String, arguments: [String], environment: [String: String]) throws {
        var env = environment
        env["TERM"] = "dumb"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let configuration = PTYProcess.Configuration(
            executable: executable, arguments: arguments, environment: env, size: TerminalSize(columns: 200, rows: 50))
        // One stream keeps output in order; a Task per chunk would not.
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        process = try PTYProcess(
            configuration,
            onOutput: { continuation.yield(.output($0)) },
            onExit: { continuation.yield(.exited($0)); continuation.finish() })
        pump = Task { [weak self] in
            for await event in stream { await self?.handle(event) }
        }
    }

    /// Waits until output matching `pattern` (a case-insensitive regular expression)
    /// appears after the previous match, and returns the matched text.
    @discardableResult
    public func expect(_ pattern: String, timeout: Duration = .seconds(15)) async throws -> String {
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let deadline = ContinuousClock.now + timeout
        while true {
            if let match = firstMatch(regex) { return match }
            if let exitStatus { throw ExpectError.exited(exitStatus, transcript: transcript) }
            guard ContinuousClock.now < deadline else {
                throw ExpectError.timedOut(pattern: pattern, transcript: transcript)
            }
            await waitForChange(until: deadline)
        }
    }

    /// Waits for whichever pattern appears first and returns its index.
    public func expectAny(_ patterns: [String], timeout: Duration = .seconds(15)) async throws -> Int {
        let regexes = try patterns.map { try NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        let deadline = ContinuousClock.now + timeout
        while true {
            for (index, regex) in regexes.enumerated() where firstMatch(regex) != nil { return index }
            if let exitStatus { throw ExpectError.exited(exitStatus, transcript: transcript) }
            guard ContinuousClock.now < deadline else {
                throw ExpectError.timedOut(pattern: patterns.joined(separator: " | "), transcript: transcript)
            }
            await waitForChange(until: deadline)
        }
    }

    public func sendLine(_ text: String) {
        process?.write(text + "\r")
    }

    /// Waits for the program to exit and returns its status and full transcript.
    public func waitForExit(timeout: Duration = .seconds(30)) async -> (TerminationStatus?, String) {
        let deadline = ContinuousClock.now + timeout
        while exitStatus == nil, ContinuousClock.now < deadline {
            await waitForChange(until: deadline)
        }
        if exitStatus == nil { process?.terminate(signal: SIGKILL) }
        return (exitStatus, transcript)
    }

    // MARK: Private

    private func handle(_ event: Event) {
        switch event {
        case .output(let data): transcript += ANSIStripper.plainText(from: data)
        case .exited(let status): exitStatus = status
        }
        let pending = waiters
        waiters.removeAll()
        pending.values.forEach { $0.resume() }
    }

    private func firstMatch(_ regex: NSRegularExpression) -> String? {
        let length = transcript.utf16.count
        let searchRange = NSRange(location: consumedOffset, length: max(0, length - consumedOffset))
        guard let match = regex.firstMatch(in: transcript, range: searchRange),
              let range = Range(match.range, in: transcript) else { return nil }
        consumedOffset = NSMaxRange(match.range)
        return String(transcript[range])
    }

    private func waitForChange(until deadline: ContinuousClock.Instant) async {
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(until: deadline)
            await self?.expire(id)
        }
        await withCheckedContinuation { waiters[id] = $0 }
        timer.cancel()
    }

    private func expire(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
