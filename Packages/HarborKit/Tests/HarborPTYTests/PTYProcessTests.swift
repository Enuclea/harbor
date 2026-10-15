import Foundation
import HarborCore
@testable import HarborPTY
import os
import Testing

/// Collects PTY output and the exit status for assertions.
private final class Capture: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (Data(), TerminationStatus?.none))
    private let exited = AsyncStream<TerminationStatus>.makeStream()

    var output: String { state.withLock { String(decoding: $0.0, as: UTF8.self) } }

    func append(_ data: Data) { state.withLock { $0.0.append(data) } }

    func finish(_ status: TerminationStatus) {
        state.withLock { $0.1 = status }
        exited.continuation.yield(status)
        exited.continuation.finish()
    }

    func waitForExit() async -> TerminationStatus? {
        for await status in exited.stream { return status }
        return state.withLock { $0.1 }
    }
}

private func spawn(_ executable: String, _ arguments: [String], capture: Capture) throws -> PTYProcess {
    try PTYProcess(
        .init(executable: executable, arguments: arguments, environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]),
        onOutput: capture.append, onExit: capture.finish)
}

@Suite("PTYProcess")
struct PTYProcessTests {
    @Test func capturesOutputAndCleanExit() async throws {
        let capture = Capture()
        let process = try spawn("/bin/echo", ["hello from harbor"], capture: capture)
        let status = await capture.waitForExit()
        #expect(status == .exited(0))
        #expect(capture.output.contains("hello from harbor"))
        _ = process
    }

    @Test func reportsNonZeroExit() async throws {
        let capture = Capture()
        let process = try spawn("/bin/sh", ["-c", "exit 3"], capture: capture)
        #expect(await capture.waitForExit() == .exited(3))
        _ = process
    }

    @Test func childHasControllingTerminal() async throws {
        let capture = Capture()
        // `tty` fails with "not a tty" unless stdin is the PTY slave.
        let process = try spawn("/bin/sh", ["-c", "tty && test -t 0 && echo TTY_OK"], capture: capture)
        #expect(await capture.waitForExit() == .exited(0))
        #expect(capture.output.contains("/dev/ttys"))
        #expect(capture.output.contains("TTY_OK"))
        _ = process
    }

    @Test func roundTripsInput() async throws {
        let capture = Capture()
        let process = try spawn("/bin/sh", ["-c", "read line; echo \"got:$line\""], capture: capture)
        process.write("harbor\r")
        #expect(await capture.waitForExit() == .exited(0))
        #expect(capture.output.contains("got:harbor"))
    }

    @Test func appliesWindowSize() async throws {
        let capture = Capture()
        let process = try PTYProcess(
            .init(executable: "/bin/sh", arguments: ["-c", "sleep 0.3; stty size"], environment: ["PATH": "/usr/bin:/bin"],
                  size: TerminalSize(columns: 80, rows: 24)),
            onOutput: capture.append, onExit: capture.finish)
        process.resize(TerminalSize(columns: 132, rows: 43))
        #expect(await capture.waitForExit() == .exited(0))
        #expect(capture.output.contains("43 132"))
    }

    @Test func doesNotLeakDescriptors() async throws {
        let capture = Capture()
        // Only 0, 1, 2 (and the descriptor ls itself opens) should be visible.
        let process = try spawn("/bin/sh", ["-c", "ls /dev/fd | wc -l"], capture: capture)
        #expect(await capture.waitForExit() == .exited(0))
        let count = Int(capture.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 99
        #expect(count <= 5)
        _ = process
    }

    @Test func expectDrivesInteractivePrograms() async throws {
        let session = try await ExpectSession.launch(
            executable: "/bin/sh", arguments: ["-c", "printf 'Passphrase: '; read -r p; echo \"len=${#p}\""])
        try await session.expect("passphrase:")
        await session.sendLine("s3cret")
        let match = try await session.expect(#"len=\d+"#)
        #expect(match == "len=6")
        let (status, _) = await session.waitForExit()
        #expect(status == .exited(0))
    }
}
