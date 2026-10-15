import Foundation
import os

/// A long-running tunnel client (`cloudflared`) whose output is watched line by line.
final class TunnelProcess: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onLine: @Sendable (String) -> Void

    private struct State {
        var partial = ""
        var lines: [String] = []
        var waiters: [(NSRegularExpression, CheckedContinuation<String?, Never>)] = []
        var exited = false
    }

    init(executable: String, arguments: [String], environment: [String: String], onLine: @escaping @Sendable (String) -> Void) throws {
        self.onLine = onLine
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.markExited()
            } else {
                self?.ingest(String(decoding: data, as: UTF8.self))
            }
        }
        process.terminationHandler = { [weak self] _ in self?.markExited() }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    /// Returns the first match of `pattern` in the output (past or future), or nil on
    /// timeout or exit.
    func firstMatch(of pattern: String, timeout: Duration) async -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.expire(regex)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            let immediate: String?? = state.withLock { state in
                if let match = state.lines.lazy.compactMap({ Self.match(regex, in: $0) }).first { return .some(match) }
                if state.exited { return .some(nil) }
                state.waiters.append((regex, continuation))
                return .none
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func ingest(_ text: String) {
        let (completed, resumed) = state.withLock { state -> ([String], [(CheckedContinuation<String?, Never>, String)]) in
            var completed: [String] = []
            var resumed: [(CheckedContinuation<String?, Never>, String)] = []
            state.partial += text
            while let newline = state.partial.firstIndex(of: "\n") {
                let line = String(state.partial[..<newline])
                state.partial.removeSubrange(...newline)
                completed.append(line)
                state.lines.append(line)
                if state.lines.count > 500 { state.lines.removeFirst(100) }
                state.waiters.removeAll { regex, continuation in
                    guard let match = Self.match(regex, in: line) else { return false }
                    resumed.append((continuation, match))
                    return true
                }
            }
            return (completed, resumed)
        }
        completed.forEach(onLine)
        resumed.forEach { $0.0.resume(returning: $0.1) }
    }

    private func markExited() {
        let waiters = state.withLock { state -> [(NSRegularExpression, CheckedContinuation<String?, Never>)] in
            state.exited = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        waiters.forEach { $0.1.resume(returning: nil) }
    }

    private func expire(_ regex: NSRegularExpression) {
        let expired = state.withLock { state -> [CheckedContinuation<String?, Never>] in
            var removed: [CheckedContinuation<String?, Never>] = []
            state.waiters.removeAll { candidate, continuation in
                guard candidate === regex else { return false }
                removed.append(continuation)
                return true
            }
            return removed
        }
        expired.forEach { $0.resume(returning: nil) }
    }

    private static func match(_ regex: NSRegularExpression, in line: String) -> String? {
        guard let result = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(result.range, in: line) else { return nil }
        return String(line[range])
    }

    deinit { terminate() }
}
