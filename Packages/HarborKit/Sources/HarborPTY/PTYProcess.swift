import CHarborPTY
import Darwin
import Foundation
import HarborCore
import HarborLogging
import os

/// How a PTY child ended.
public enum TerminationStatus: Sendable, Equatable, CustomStringConvertible {
    case exited(Int32)
    case signaled(Int32)

    public var isClean: Bool { self == .exited(0) }

    public var exitCode: Int32 {
        switch self {
        case .exited(let code): code
        case .signaled(let signal): 128 + signal
        }
    }

    public var description: String {
        switch self {
        case .exited(let code): "exited with status \(code)"
        case .signaled(let signal): "terminated by signal \(signal)"
        }
    }
}

public enum PTYError: Error, LocalizedError {
    case spawnFailed(executable: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let executable, let code):
            "Could not start \(executable): \(String(cString: strerror(code)))"
        }
    }
}

/// A child process attached to a pseudo-terminal.
///
/// Output is read on a dedicated serial queue in 64 KiB chunks and handed to `onOutput`
/// *on that queue* — consumers must be thread-safe and quick. Writes are queued and
/// back-pressured, so pasting megabytes never blocks the caller.
public final class PTYProcess: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var executable: String
        /// argv[0]. A leading `-` asks shells to behave as login shells.
        public var argv0: String
        public var arguments: [String]
        public var environment: [String: String]
        public var workingDirectory: String?
        public var size: TerminalSize

        public init(executable: String, argv0: String? = nil, arguments: [String] = [], environment: [String: String],
                    workingDirectory: String? = nil, size: TerminalSize = .standard) {
            self.executable = executable
            self.argv0 = argv0 ?? (executable as NSString).lastPathComponent
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory
            self.size = size
        }
    }

    public let pid: pid_t
    public let configuration: Configuration

    private let masterFD: Int32
    /// Guards `masterFD` against being closed while another thread queries it.
    private let descriptorOpen = OSAllocatedUnfairLock(initialState: true)
    private let queue: DispatchQueue
    private let log = Log(.pty)
    private let onOutput: @Sendable (Data) -> Void
    private let onExit: @Sendable (TerminationStatus) -> Void

    // Mutated only on `queue`.
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var processSource: DispatchSourceProcess?
    private var pendingWrites = Data()
    private var exitStatus: TerminationStatus?
    private var reachedEOF = false
    private var finished = false
    private let readBuffer = UnsafeMutableRawPointer.allocate(byteCount: 65_536, alignment: 16)

    /// Spawns the process and starts reading immediately.
    public init(
        _ configuration: Configuration,
        onOutput: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (TerminationStatus) -> Void
    ) throws {
        self.configuration = configuration
        self.onOutput = onOutput
        self.onExit = onExit
        queue = DispatchQueue(label: "harbor.pty.\(configuration.argv0)", qos: .userInteractive)

        let argv = [configuration.argv0] + configuration.arguments
        let envp = configuration.environment.map { "\($0.key)=\($0.value)" }
        var master: Int32 = -1
        var childPID: pid_t = 0
        let result = Self.withCStringArray(argv) { cArgv in
            Self.withCStringArray(envp) { cEnvp in
                harbor_pty_spawn(
                    configuration.executable, cArgv, cEnvp, configuration.workingDirectory,
                    UInt16(clamping: configuration.size.rows), UInt16(clamping: configuration.size.columns),
                    &master, &childPID)
            }
        }
        guard result == 0 else {
            readBuffer.deallocate()
            throw PTYError.spawnFailed(executable: configuration.executable, errno: result)
        }
        masterFD = master
        pid = childPID
        log.info("spawned \(configuration.argv0)", ["pid": "\(childPID)", "size": configuration.size.description])
        queue.async { self.startSources() }
    }

    deinit {
        // Sources hold the descriptor; an un-cancelled read source would spin on readable data.
        readSource?.cancel()
        writeSource?.cancel()
        processSource?.cancel()
        readBuffer.deallocate()
    }

    // MARK: Input

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async {
            guard !self.finished else { return }
            self.pendingWrites.append(data)
            self.flushWrites()
        }
    }

    public func write(_ text: String) {
        write(Data(text.utf8))
    }

    public func resize(_ size: TerminalSize, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        queue.async {
            guard !self.finished else { return }
            _ = harbor_pty_set_size(self.masterFD, UInt16(clamping: size.rows), UInt16(clamping: size.columns),
                                    UInt16(clamping: pixelWidth), UInt16(clamping: pixelHeight))
        }
    }

    /// Sends `signal` to the whole process group (SIGHUP mirrors closing a terminal window).
    public func terminate(signal: Int32 = SIGHUP) {
        queue.async {
            guard !self.finished else { return }
            if killpg(self.pid, signal) != 0 { kill(self.pid, signal) }
        }
    }

    // MARK: Introspection

    /// The program currently in the foreground (e.g. `vim` while editing, the shell otherwise).
    public var foregroundProcess: ProcessSnapshot? {
        let group = descriptorOpen.withLock { open in open ? harbor_pty_foreground_pgid(masterFD) : -1 }
        guard group != -1 else { return nil }
        return ProcessSnapshot(pid: group > 0 ? group : pid)
    }

    /// True when something other than the top-level process is in the foreground —
    /// used to confirm before closing a tab that is running a job.
    public var hasForegroundJob: Bool {
        guard let foreground = foregroundProcess else { return false }
        return foreground.pid != pid
    }

    // MARK: Event sources

    private func startSources() {
        let read = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        read.setEventHandler { [weak self] in self?.drainOutput() }
        read.setCancelHandler { [masterFD, descriptorOpen] in
            descriptorOpen.withLock { open in
                close(masterFD)
                open = false
            }
        }
        readSource = read
        read.resume()

        let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        process.setEventHandler { [weak self] in self?.handleProcessExit() }
        processSource = process
        process.resume()

        // The child may have exited before the source was armed.
        handleProcessExit()
    }

    private func drainOutput() {
        while true {
            let count = Darwin.read(masterFD, readBuffer, 65_536)
            if count > 0 {
                onOutput(Data(bytes: readBuffer, count: count))
                continue
            }
            if count == 0 || (errno != EAGAIN && errno != EINTR) {
                // EIO: every slave descriptor is closed — the child and its descendants are gone.
                reachedEOF = true
                readSource?.cancel()
                readSource = nil
                finishIfPossible()
            }
            return
        }
    }

    private func handleProcessExit() {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            exitStatus = Self.decode(status)
        } else if result == -1, errno == ECHILD, kill(pid, 0) == -1 {
            // Reaped elsewhere; the process is gone either way.
            exitStatus = .exited(0)
        } else {
            return // still running
        }
        processSource?.cancel()
        processSource = nil
        // Read whatever is still buffered, then give background children a moment
        // before reporting so the final output isn't cut off.
        drainOutput()
        queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
            self?.reachedEOF = true
            self?.finishIfPossible()
        }
    }

    private func finishIfPossible() {
        guard !finished, reachedEOF, let exitStatus else { return }
        finished = true
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        pendingWrites.removeAll()
        log.info("process \(pid) \(exitStatus)")
        onExit(exitStatus)
    }

    private func flushWrites() {
        while !pendingWrites.isEmpty {
            let written = pendingWrites.withUnsafeBytes { Darwin.write(masterFD, $0.baseAddress, $0.count) }
            if written > 0 {
                pendingWrites.removeFirst(written)
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                armWriteSource()
                return
            } else {
                log.warning("write to pty failed: \(String(cString: strerror(errno)))")
                pendingWrites.removeAll()
                return
            }
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func armWriteSource() {
        guard writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: queue)
        source.setEventHandler { [weak self] in self?.flushWrites() }
        writeSource = source
        source.resume()
    }

    // MARK: Helpers

    private static func decode(_ status: Int32) -> TerminationStatus {
        let signal = status & 0x7F
        if signal == 0 { return .exited((status >> 8) & 0xFF) }
        return .signaled(signal)
    }

    private static func withCStringArray<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
