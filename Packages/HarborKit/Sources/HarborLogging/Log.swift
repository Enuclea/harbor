import Foundation
import HarborCore
import os

/// Routes log entries to the configured sinks and holds the global level.
public final class LogHub: Sendable {
    public static let shared = LogHub()

    private struct State: Sendable {
        var sinks: [any LogSink] = []
        var minimumLevel: LogLevel = .info
        var nextID: UInt64 = 1
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public var minimumLevel: LogLevel {
        get { state.withLock { $0.minimumLevel } }
        set { state.withLock { $0.minimumLevel = newValue } }
    }

    public func add(_ sink: any LogSink) {
        state.withLock { $0.sinks.append(sink) }
    }

    func shouldLog(_ level: LogLevel) -> Bool {
        level >= minimumLevel
    }

    func dispatch(level: LogLevel, category: LogCategory, message: String, metadata: [String: String]) {
        let (id, sinks) = state.withLock { state -> (UInt64, [any LogSink]) in
            defer { state.nextID += 1 }
            return (state.nextID, state.sinks)
        }
        let entry = LogEntry(id: id, date: Date(), level: level, category: category, message: message, metadata: metadata)
        for sink in sinks { sink.write(entry) }
    }
}

/// A category-scoped logger. Create one per type: `private let log = Log(.ssh)`.
///
/// Messages go to the unified log (Console.app) and to every sink on `LogHub` —
/// the rotating file and the in-app viewer. Never log secrets; use `Redactor` for
/// anything that might contain user data.
public struct Log: Sendable {
    public let category: LogCategory
    private let logger: Logger
    private let hub: LogHub

    public init(_ category: LogCategory, hub: LogHub = .shared) {
        self.category = category
        self.logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: category.rawValue)
        self.hub = hub
    }

    public func debug(_ message: @autoclosure () -> String, _ metadata: [String: String] = [:]) {
        emit(.debug, message, metadata)
    }

    public func info(_ message: @autoclosure () -> String, _ metadata: [String: String] = [:]) {
        emit(.info, message, metadata)
    }

    public func notice(_ message: @autoclosure () -> String, _ metadata: [String: String] = [:]) {
        emit(.notice, message, metadata)
    }

    public func warning(_ message: @autoclosure () -> String, _ metadata: [String: String] = [:]) {
        emit(.warning, message, metadata)
    }

    public func error(_ message: @autoclosure () -> String, _ metadata: [String: String] = [:]) {
        emit(.error, message, metadata)
    }

    public func error(_ message: @autoclosure () -> String, error: Error, _ metadata: [String: String] = [:]) {
        var metadata = metadata
        metadata["error"] = error.localizedDescription
        emit(.error, message, metadata)
    }

    public func fault(_ message: @autoclosure () -> String, _ metadata: [String: String] = [:]) {
        emit(.fault, message, metadata)
    }

    private func emit(_ level: LogLevel, _ message: () -> String, _ metadata: [String: String]) {
        guard hub.shouldLog(level) else { return }
        let text = message()
        logger.log(level: level.osLogType, "\(text, privacy: .public)")
        hub.dispatch(level: level, category: category, message: text, metadata: metadata)
    }
}

extension LogLevel {
    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .warning: .default
        case .error: .error
        case .fault: .fault
        }
    }
}
