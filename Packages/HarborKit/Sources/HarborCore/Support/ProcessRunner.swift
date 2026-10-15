import Foundation
import os

/// The captured result of a finished child process.
public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var succeeded: Bool { status == 0 }
    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, LocalizedError {
    case launchFailed(String, underlying: Error)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let path, let error): "Could not launch \(path): \(error.localizedDescription)"
        case .timedOut(let path): "\(path) did not finish in time"
        }
    }
}

/// Runs short-lived helper commands (`ssh-keygen -l`, `ssh-add -l`, `tailscale status`…)
/// without a terminal. Both pipes are drained concurrently so large output can't deadlock.
public enum ProcessRunner {
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        input: Data? = nil,
        timeout: Duration = .seconds(30)
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = input == nil ? FileHandle.nullDevice : stdinPipe

        let exit = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { exit.continuation.yield($0.terminationStatus); exit.continuation.finish() }

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(executable, underlying: error)
        }

        if let input {
            let handle = stdinPipe.fileHandleForWriting
            try? handle.write(contentsOf: input)
            try? handle.close()
        }

        async let stdout = readAll(stdoutPipe.fileHandleForReading)
        async let stderr = readAll(stderrPipe.fileHandleForReading)

        let didTimeOut = OSAllocatedUnfairLock(initialState: false)
        let pid = process.processIdentifier
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            didTimeOut.withLock { $0 = true }
            kill(pid, SIGTERM)
        }

        var status: Int32 = -1
        for await code in exit.stream { status = code }
        watchdog.cancel()
        let (out, err) = await (stdout, stderr)
        if didTimeOut.withLock({ $0 }) {
            throw ProcessRunnerError.timedOut(executable)
        }
        return ProcessResult(status: status, stdout: out, stderr: err)
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        await Task.detached { (try? handle.readToEnd()) ?? Data() }.value
    }
}

/// Finds command-line tools. GUI apps inherit a minimal `PATH`, so common install
/// prefixes (Homebrew on both architectures, MacPorts, Nix) are searched explicitly.
public enum ExecutableLocator {
    public static let searchPaths = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        "/opt/local/bin", "/run/current-system/sw/bin",
        "/Applications/Tailscale.app/Contents/MacOS",
    ]

    public static func find(_ name: String, extraPaths: [String] = []) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        for directory in extraPaths + envPaths + searchPaths where seen.insert(directory).inserted {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
