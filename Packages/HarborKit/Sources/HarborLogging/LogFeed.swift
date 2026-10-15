import Foundation
import HarborCore
import Observation
import os

/// The most recent log entries, observable by the in-app log viewer.
@MainActor
@Observable
public final class LogFeed {
    public private(set) var entries: [LogEntry] = []
    @ObservationIgnored public let capacity: Int

    public init(capacity: Int = 2_000) {
        self.capacity = capacity
    }

    /// A sink that feeds this object. Entries are batched so a log storm can't flood the main thread.
    public nonisolated func makeSink() -> any LogSink {
        LogFeedSink(feed: self)
    }

    public func clear() {
        entries.removeAll()
    }

    fileprivate func append(_ batch: [LogEntry]) {
        entries.append(contentsOf: batch)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }
}

private final class LogFeedSink: LogSink {
    private struct State: Sendable {
        var pending: [LogEntry] = []
        var flushScheduled = false
    }

    private let feed: LogFeed
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(feed: LogFeed) {
        self.feed = feed
    }

    func write(_ entry: LogEntry) {
        let shouldSchedule = state.withLock { state -> Bool in
            state.pending.append(entry)
            if state.flushScheduled { return false }
            state.flushScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task { @MainActor [feed, state] in
            try? await Task.sleep(for: .milliseconds(100))
            let batch = state.withLock { state -> [LogEntry] in
                defer { state.pending.removeAll(); state.flushScheduled = false }
                return state.pending
            }
            feed.append(batch)
        }
    }
}
