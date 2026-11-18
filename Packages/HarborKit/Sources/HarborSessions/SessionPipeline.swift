import Foundation
import HarborCore
import HarborLogging
import os

/// Recent output kept so a newly attached viewer (e.g. a browser) can rebuild the screen.
struct ReplayBuffer: Sendable {
    let capacity: Int
    private(set) var data = Data()

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func append(_ chunk: Data) {
        data.append(chunk)
        guard data.count > capacity else { return }
        var cut = data.count - capacity * 3 / 4
        // Start replay on a line boundary to avoid beginning mid-escape-sequence where possible.
        let searchStart = data.startIndex + cut
        if let newline = data[searchStart...].firstIndex(of: 0x0A) {
            cut = newline - data.startIndex + 1
        }
        data = data.subdata(in: (data.startIndex + cut)..<data.endIndex)
    }
}

/// Fans one session's PTY output out to every consumer, on the PTY's read queue:
/// renderer, browsers, recorder, replay buffer, command captures and the OSC scanner.
///
/// Attaching takes the replay snapshot and registers the subscriber under one lock,
/// so a late viewer never sees a gap or a duplicate.
public final class SessionPipeline: Sendable {
    public typealias Subscriber = @Sendable (Data) -> Void

    struct Handlers: Sendable {
        var events: @Sendable ([OSCEvent]) -> Void = { _ in }
        var activity: @Sendable () -> Void = {}
    }

    private struct State: Sendable {
        var scanner = OSCScanner()
        var subscribers: [UUID: Subscriber] = [:]
        var replay = ReplayBuffer(capacity: 512 * 1024)
        var captures: [UUID: Data] = [:]
        var recorder: SessionRecorder?
        var activityFlagged = false
        var lastOutput: ContinuousClock.Instant?
        var handlers = Handlers()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    func setHandlers(_ handlers: Handlers) {
        state.withLock { $0.handlers = handlers }
    }

    func setRecorder(_ recorder: SessionRecorder?) {
        state.withLock { $0.recorder = recorder }
    }

    /// Called for every chunk read from the PTY.
    func ingest(_ data: Data, markActivity: Bool = true) {
        let (subscribers, events, flagActivity, recorder, handlers) = state.withLock { state in
            state.replay.append(data)
            for key in state.captures.keys { state.captures[key]?.append(data) }
            var flag = false
            if markActivity {
                state.lastOutput = .now
                flag = !state.activityFlagged
                state.activityFlagged = true
            }
            return (Array(state.subscribers.values), state.scanner.scan(data), flag, state.recorder, state.handlers)
        }
        for subscriber in subscribers { subscriber(data) }
        recorder?.record(output: data)
        if !events.isEmpty { handlers.events(events) }
        if flagActivity { handlers.activity() }
    }

    // MARK: Subscribers

    /// Registers `subscriber` and returns the replay that precedes its first delivery.
    public func attach(_ subscriber: @escaping Subscriber) -> (token: UUID, replay: Data) {
        let token = UUID()
        let replay = state.withLock { state -> Data in
            state.subscribers[token] = subscriber
            return state.replay.data
        }
        return (token, replay)
    }

    /// Registers a subscriber that needs no replay (the native view, attached before start).
    public func subscribe(_ subscriber: @escaping Subscriber) -> UUID {
        attach(subscriber).token
    }

    public func detach(_ token: UUID) {
        _ = state.withLock { $0.subscribers.removeValue(forKey: token) }
    }

    public var replay: Data { state.withLock { $0.replay.data } }

    // MARK: Activity

    /// Re-arms the "new output" notification after the user has looked at the tab.
    func resetActivity() {
        state.withLock { $0.activityFlagged = false }
    }

    var lastOutputAt: ContinuousClock.Instant? { state.withLock { $0.lastOutput } }

    // MARK: Captures

    func beginCapture() -> UUID {
        let id = UUID()
        state.withLock { $0.captures[id] = Data() }
        return id
    }

    func capturedData(_ id: UUID) -> Data {
        state.withLock { $0.captures[id] ?? Data() }
    }

    @discardableResult
    func endCapture(_ id: UUID) -> Data {
        state.withLock { $0.captures.removeValue(forKey: id) ?? Data() }
    }
}
