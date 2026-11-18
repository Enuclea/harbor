import Foundation
import HarborControl
import HarborCore
import HarborLogging
import HarborPTY
import Observation

/// Owns every open session: creates them, keeps their process info fresh, applies the
/// exit behaviour, and tells streaming clients what changed.
@MainActor
@Observable
public final class SessionManager {
    public private(set) var sessions: [TerminalSession] = []

    @ObservationIgnored public weak var presenter: (any SessionPresenting)?
    /// Called when a session's process ends, before any auto-close. Used for failure diagnosis.
    @ObservationIgnored public var onSessionEnded: ((TerminalSession) -> Void)?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let hosts: HostLibrary
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let planner: SessionLaunchPlanner
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<ControlEvent>.Continuation] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let log = Log(.session)

    /// - Parameter environment: The environment sessions inherit (overridable for tests).
    public init(settings: SettingsStore, hosts: HostLibrary, paths: AppPaths,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.settings = settings
        self.hosts = hosts
        self.paths = paths
        self.environment = environment
        planner = SessionLaunchPlanner(paths: paths)
    }

    public func session(_ id: SessionID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    // MARK: Opening

    /// Creates a session, has the presenter show it (so the renderer subscribes first), then starts it.
    @discardableResult
    public func open(_ kind: SessionKind, workingDirectory: String? = nil, placement: SessionPlacement = .newTab) -> TerminalSession {
        let effectiveKind: SessionKind
        switch kind {
        case .ssh(let host):
            effectiveKind = .ssh(hosts.host(id: host.id) ?? host)
        default:
            effectiveKind = kind
        }
        let current = settings.settings
        let size = TerminalSize(columns: current.appearance.initialColumns, rows: current.appearance.initialRows)
        let id = SessionID()
        let session: TerminalSession
        do {
            let configuration = try planner.configuration(
                for: effectiveKind, settings: current, workingDirectory: workingDirectory, size: size, sessionID: id,
                inheritedEnvironment: environment)
            session = TerminalSession(id: id, kind: effectiveKind, configuration: configuration)
        } catch {
            session = TerminalSession(id: id, kind: effectiveKind, configuration: nil, launchError: error.localizedDescription)
        }
        session.setRecorder(makeRecorder(for: session, size: size, mode: current.logging.sessionRecording))
        session.configurationProvider = { [weak self] session in self?.replanConfiguration(for: session) }
        session.onTerminated = { [weak self] in self?.sessionEnded($0) }
        session.onUpdated = { [weak self] in self?.broadcast(.sessionUpdated($0.id.description)) }
        sessions.append(session)

        presenter?.present(session, placement: placement)
        session.start()

        if let host = effectiveKind.host, hosts.host(id: host.id) != nil {
            hosts.markConnected(id: host.id)
        }
        log.info("opened \(effectiveKind.label) session \(id.shortDescription)")
        broadcast(.sessionOpened(id.description))
        startRefreshing()
        return session
    }

    private func replanConfiguration(for session: TerminalSession) -> (kind: SessionKind, configuration: PTYProcess.Configuration)? {
        let current = settings.settings
        let updatedKind: SessionKind
        switch session.kind {
        case .ssh(let host):
            updatedKind = .ssh(hosts.host(id: host.id) ?? host)
        default:
            updatedKind = session.kind
        }
        guard let configuration = try? planner.configuration(
            for: updatedKind, settings: current, workingDirectory: session.workingDirectory, size: session.size,
            sessionID: session.id, inheritedEnvironment: environment)
        else { return nil }
        return (updatedKind, configuration)
    }

    // MARK: Closing

    /// Closes a session programmatically (assistant, browser, exit behaviour): hangs up
    /// the process and removes its tab.
    public func close(_ session: TerminalSession) {
        guard sessions.contains(where: { $0 === session }) else { return }
        presenter?.dismiss(session)
        remove(session)
    }

    /// The user closed the tab's window; the window is already gone.
    public func windowDidClose(for session: TerminalSession) {
        remove(session)
    }

    private func remove(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        session.terminate()
        session.setRecorder(nil)
        sessions.remove(at: index)
        broadcast(.sessionClosed(session.id.description))
        if sessions.isEmpty {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    private func sessionEnded(_ session: TerminalSession) {
        onSessionEnded?(session)
        broadcast(.sessionUpdated(session.id.description))
        let behavior = settings.settings.terminal.exitBehavior
        let clean: Bool = if case .exited(let status) = session.state { status.isClean } else { false }
        switch behavior {
        case .close: close(session)
        case .closeIfClean where clean: close(session)
        default: break
        }
    }

    // MARK: Events

    public func events() -> AsyncStream<ControlEvent> {
        let (stream, continuation) = AsyncStream<ControlEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    private func broadcast(_ event: ControlEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    // MARK: Housekeeping

    private func startRefreshing() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sessions.forEach { $0.refreshProcessInfo() }
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    private func makeRecorder(for session: TerminalSession, size: TerminalSize, mode: SessionRecordingMode) -> SessionRecorder? {
        let format: SessionRecorder.Format
        switch mode {
        case .off: return nil
        case .text: format = .text
        case .asciicast: format = .asciicast
        }
        do {
            return try SessionRecorder(
                directory: paths.sessionRecordings, title: session.title, format: format, size: size,
                environment: ProcessInfo.processInfo.environment)
        } catch {
            log.warning("could not start session recording: \(error.localizedDescription)")
            return nil
        }
    }
}
