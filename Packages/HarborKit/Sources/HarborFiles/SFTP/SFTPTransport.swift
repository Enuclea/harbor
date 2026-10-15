import Foundation
import HarborCore
import HarborSSH
import os

/// A byte pipe to an SFTP server.
public protocol SFTPTransport: Sendable {
    /// Bytes from the server, in order. Finishes when the connection closes.
    var incoming: AsyncStream<Data> { get }
    func send(_ data: Data)
    func close()
    /// Diagnostic text (e.g. ssh's stderr) explaining why the connection closed.
    var closeReason: String { get }
}

/// Runs a process that speaks SFTP on stdin/stdout — `ssh -s host sftp` in the app,
/// `/usr/libexec/sftp-server` in tests.
public final class ProcessSFTPTransport: SFTPTransport, @unchecked Sendable {
    public let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let writeQueue = DispatchQueue(label: "harbor.sftp.write")
    private let stderrText = OSAllocatedUnfairLock(initialState: "")

    public init(command: CommandSpec) throws {
        (incoming, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let continuation = continuation
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        let stderrText = stderrText
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            stderrText.withLock { $0 += String(decoding: data, as: UTF8.self) }
        }
        // The stream finishes on stdout EOF rather than on termination, so the last
        // bytes are never dropped. Writers must ignore SIGPIPE (the app does at launch).
        try process.run()
    }

    public func send(_ data: Data) {
        let handle = input.fileHandleForWriting
        writeQueue.async { try? handle.write(contentsOf: data) }
    }

    public func close() {
        writeQueue.async { [input, process] in
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
    }

    public var closeReason: String {
        stderrText.withLock { $0 }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    deinit {
        if process.isRunning { process.terminate() }
    }
}
