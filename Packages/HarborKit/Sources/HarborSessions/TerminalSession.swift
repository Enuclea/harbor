import Foundation
import HarborCore
import HarborLogging
import HarborPTY
import Observation

/// One terminal tab: a process under a PTY plus everything learned from its output.
///
/// Rendering is not done here — the UI subscribes to `pipeline`. That keeps sessions
/// usable headless (tests, browsers, assistants) and the renderer swappable.
@MainActor
@Observable
public final class TerminalSession: Identifiable {
    public let id: SessionID
    public let kind: SessionKind
    public let createdAt = Date()

    public private(set) var state: SessionState = .starting
    /// Reported by the shell (OSC 7), or read from the process when integration is absent.
    public private(set) var workingDirectory: String?
    /// Set by programs with OSC 0/2.
    public private(set) var programTitle: String?
    /// Set by the user (Rename Tab).
    public var customTitle: String?
    public private(set) var foregroundProcessName: String?
    /// The shell that announced Harbor integration, e.g. `zsh`.
    public private(set) var shellIntegration: String?
    public private(set) var isAtPrompt = false
    public private(set) var lastCommand: CommandRecord?
    public private(set) var size: TerminalSize
    /// Output arrived since the user last looked at this tab.
    public private(set) var hasUnseenActivity = false
    /// When an assistant last acted on this tab, for the activity indicator.
    public private(set) var assistantActivityAt: Date?
    /// The command line currently running, as reported by shell integration (zsh, fish).
    public private(set) var runningCommand: String?
    /// The most recent command line, kept after it finishes — from shell integration, or
    /// from what an assistant typed (which works even on hosts without integration).
    public private(set) var lastCommandLine: String?
    /// Whether `lastCommandLine` was submitted by an AI assistant.
    public private(set) var lastCommandFromAssistant = false
    /// Output arrived recently without the user typing — a program is producing output.
    public private(set) var isStreamingOutput = false
    /// The bell rang while the user wasn't looking at this tab.
    public private(set) var bellPending = false
    /// Anything has been printed yet (an SSH tab with no output is still connecting).
    public private(set) var hasOutput = false

    @ObservationIgnored public let pipeline = SessionPipeline()
    /// Supplied by the terminal view; used to answer `read_screen` precisely.
    @ObservationIgnored public weak var screen: (any ScreenReading)?
    @ObservationIgnored var onTerminated: ((TerminalSession) -> Void)?
    @ObservationIgnored var onUpdated: ((TerminalSession) -> Void)?
    /// Desktop notifications requested by programs (OSC 9 / OSC 777).
    @ObservationIgnored public var onNotification: ((_ title: String, _ body: String) -> Void)?

    @ObservationIgnored private var process: PTYProcess?
    @ObservationIgnored private let configuration: PTYProcess.Configuration?
    @ObservationIgnored private var launchError: String?
    @ObservationIgnored private var commandWaiters: [UUID: CheckedContinuation<CommandWait, Never>] = [:]
    @ObservationIgnored private let log = Log(.session)
    @ObservationIgnored private var lastInputAt: ContinuousClock.Instant?
    @ObservationIgnored private var pendingAssistantCommand: String?

    init(id: SessionID = SessionID(), kind: SessionKind, configuration: PTYProcess.Configuration?, launchError: String? = nil) {
        self.id = id
        self.kind = kind
        self.configuration = configuration
        self.launchError = launchError
        self.size = configuration?.size ?? .standard
        workingDirectory = kind == .localShell ? configuration?.workingDirectory : kind.host?.remoteDirectory

        pipeline.setHandlers(SessionPipeline.Handlers(
            events: { [weak self] events in
                // DispatchQueue.main preserves order (C before D), which Task does not guarantee.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(events) } }
            },
            activity: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.hasUnseenActivity = true
                        if self?.hasOutput == false { self?.hasOutput = true }
                    }
                }
            }))
    }

    // MARK: Lifecycle

    /// Starts the process. The renderer should subscribe to `pipeline` before this.
    func start() {
        guard process == nil, state == .starting else { return }
        guard let configuration else {
            state = .failed(launchError ?? "This session could not be configured.")
            return
        }
        launch(configuration)
    }

    /// Starts the same command again (Reconnect for SSH tabs, Restart for shells).
    public func restart() {
        guard let configuration, !state.isRunning else { return }
        pipeline.ingest(Data("\r\n\u{1B}[2m— restarted \(Date().formatted(date: .omitted, time: .standard)) —\u{1B}[0m\r\n".utf8))
        process = nil
        launch(configuration)
    }

    private func launch(_ configuration: PTYProcess.Configuration) {
        do {
            let pipeline = pipeline
            var launched = configuration
            launched.size = size
            process = try PTYProcess(
                launched,
                onOutput: { pipeline.ingest($0) },
                onExit: { [weak self] status in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.processExited(status) } }
                })
            state = .running
        } catch {
            state = .failed(error.localizedDescription)
            log.error("launch failed for \(kind.label) session", error: error)
            onTerminated?(self)
        }
    }

    /// Hangs up the process group, as closing a Terminal.app window does.
    public func terminate() {
        process?.terminate(signal: SIGHUP)
    }

    func setRecorder(_ recorder: SessionRecorder?) {
        pipeline.setRecorder(recorder)
    }

    private func processExited(_ status: TerminationStatus) {
        state = .exited(status)
        isAtPrompt = false
        isStreamingOutput = false
        runningCommand = nil
        resumeCommandWaiters(with: .sessionEnded)
        pipeline.setRecorder(nil)
        log.info("session \(id.shortDescription) \(status)")
        onTerminated?(self)
        onUpdated?(self)
    }

    // MARK: I/O

    public func send(_ data: Data) {
        guard state.isRunning else { return }
        lastInputAt = .now
        process?.write(data)
    }

    public func send(text: String) {
        send(Data(text.utf8))
    }

    public func resize(_ newSize: TerminalSize) {
        guard newSize != size else { return }
        size = newSize
        process?.resize(newSize)
    }

    public func markSeen() {
        hasUnseenActivity = false
        bellPending = false
        pipeline.resetActivity()
    }

    /// Records a bell the user didn't see (the tab or window wasn't in front).
    public func ringBell() {
        bellPending = true
    }

    func noteAssistantActivity() {
        assistantActivityAt = Date()
    }

    /// Records a command line typed on the user's behalf (by an assistant or the API).
    func noteSubmittedCommand(_ line: String, fromAssistant: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return }
        lastCommandLine = String(trimmed.prefix(200))
        lastCommandFromAssistant = fromAssistant
        pendingAssistantCommand = fromAssistant ? lastCommandLine : nil
    }

    // MARK: Derived

    public var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let programTitle, !programTitle.trimmingCharacters(in: .whitespaces).isEmpty { return programTitle }
        return derivedTitle
    }

    private var derivedTitle: String {
        switch kind {
        case .ssh(let host):
            return host.name
        case .command(_, let title):
            return title
        case .localShell:
            if let process = foregroundProcessName, !Self.isShell(process) { return process }
            return directoryDisplayName ?? "Terminal"
        }
    }

    /// `~` for home, otherwise the last path component.
    public var directoryDisplayName: String? {
        guard let workingDirectory else { return nil }
        if workingDirectory == NSHomeDirectory() { return "~" }
        return RemotePathName.last(workingDirectory)
    }

    /// Closing should be confirmed when it would interrupt something.
    public var needsCloseConfirmation: Bool {
        guard state.isRunning else { return false }
        if kind.host != nil { return true }
        return process?.hasForegroundJob ?? false
    }

    /// Polled by `SessionManager` to keep titles current and to find the working directory
    /// of shells without integration.
    func refreshProcessInfo() {
        refreshStreaming()
        guard state.isRunning, let snapshot = process?.foregroundProcess else { return }
        if foregroundProcessName != snapshot.name { foregroundProcessName = snapshot.name }
        if kind == .localShell, shellIntegration == nil, Self.isShell(snapshot.name),
           let directory = snapshot.workingDirectory, directory != workingDirectory {
            workingDirectory = directory
        }
    }

    /// Output in the last 1.5 s that isn't just the echo of the user's own typing.
    private func refreshStreaming(now: ContinuousClock.Instant = .now) {
        var streaming = false
        if state.isRunning, let output = pipeline.lastOutputAt, now - output < .milliseconds(1_500) {
            streaming = lastInputAt.map { now - $0 > .seconds(1) } ?? true
        }
        if streaming != isStreamingOutput { isStreamingOutput = streaming }
    }

    static func isShell(_ name: String) -> Bool {
        let bare = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "login"].contains(bare)
    }

    // MARK: Output events

    func apply(_ events: [OSCEvent]) {
        for event in events {
            switch event.code {
            case 7:
                if let path = Self.path(fromFileURL: event.payload) { workingDirectory = path }
            case 0, 2:
                programTitle = event.payload
            case 133:
                handleSemanticPrompt(event.payload)
            case 1337:
                handleITermExtension(event.payload)
            case 9 where !event.payload.hasPrefix("4;"):
                onNotification?(title, event.payload)
            case 777:
                let parts = event.payload.split(separator: ";", maxSplits: 2).map(String.init)
                if parts.first == "notify", parts.count == 3 { onNotification?(parts[1], parts[2]) }
            default:
                break
            }
        }
        onUpdated?(self)
    }

    private func handleSemanticPrompt(_ payload: String) {
        guard let mark = payload.first else { return }
        switch mark {
        case "A":
            isAtPrompt = true
            runningCommand = nil
        case "C":
            isAtPrompt = false
            lastCommand = CommandRecord(startedAt: Date())
        case "D":
            runningCommand = nil
            let fields = payload.split(separator: ";")
            let code = fields.count > 1 ? Int32(fields[1]) : nil
            if lastCommand?.finishedAt == nil {
                lastCommand?.finishedAt = Date()
                lastCommand?.exitCode = code
            }
            resumeCommandWaiters(with: .finished(exitCode: code))
        default:
            break
        }
    }

    private func handleITermExtension(_ payload: String) {
        if payload.hasPrefix("HarborShellIntegration=") {
            let value = payload.dropFirst("HarborShellIntegration=".count)
            shellIntegration = value.split(separator: ";").first.map(String.init)
        } else if payload.hasPrefix("HarborCommand=") {
            let encoded = payload.dropFirst("HarborCommand=".count)
            let command = String(encoded).removingPercentEncoding.map { String($0.prefix(200)) }
            runningCommand = command
            if let command, !command.isEmpty {
                lastCommandFromAssistant = command == pendingAssistantCommand
                lastCommandLine = command
            }
            pendingAssistantCommand = nil
        } else if payload.hasPrefix("CurrentDir=") {
            workingDirectory = String(payload.dropFirst("CurrentDir=".count))
        }
    }

    static func path(fromFileURL payload: String) -> String? {
        guard payload.hasPrefix("file://") else { return nil }
        if let url = URL(string: payload), !url.path.isEmpty { return url.path }
        let rest = payload.dropFirst("file://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return String(rest[slash...]).removingPercentEncoding
    }

    // MARK: Command completion

    /// Polls until the shell has drawn its prompt (OSC 133;A). Marks for the end of one
    /// command and the next prompt can arrive in separate reads.
    func waitUntilAtPrompt(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !isAtPrompt, state.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return isAtPrompt
    }

    enum CommandWait: Sendable, Equatable {
        case finished(exitCode: Int32?)
        case timedOut
        case sessionEnded
    }

    /// Registers for the next OSC 133;D, *then* runs `trigger` (typically sending the
    /// command), so even an instant completion can't be missed.
    func waitForCommandCompletion(timeout: Duration, after trigger: () -> Void) async -> CommandWait {
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.commandWaiters.removeValue(forKey: id)?.resume(returning: .timedOut)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            commandWaiters[id] = continuation
            trigger()
        }
    }

    private func resumeCommandWaiters(with result: CommandWait) {
        let waiters = commandWaiters
        commandWaiters.removeAll()
        waiters.values.forEach { $0.resume(returning: result) }
    }
}

enum RemotePathName {
    static func last(_ path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? "/"
    }
}
