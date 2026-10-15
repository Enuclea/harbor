import Foundation
import HarborCore

/// Subsystems that log. Each maps to an `os.Logger` category, so Console.app can filter
/// by `subsystem:dev.harbor.Harbor category:ssh`.
public enum LogCategory: String, Codable, Sendable, CaseIterable {
    case app, session, pty, shell, ssh, sftp, control, mcp, remote, tunnel, doctor, settings, ui
}

public struct LogEntry: Codable, Sendable, Identifiable, Hashable {
    public let id: UInt64
    public let date: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    public let metadata: [String: String]

    public init(id: UInt64, date: Date, level: LogLevel, category: LogCategory, message: String, metadata: [String: String]) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
    }

    /// Single-line rendering for the log viewer and plain-text exports.
    public var formatted: String {
        let time = date.formatted(.iso8601.time(includingFractionalSeconds: true))
        let meta = metadata.isEmpty ? "" : " " + metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "\(time) [\(level.rawValue.uppercased())] \(category.rawValue): \(message)\(meta)"
    }
}

/// Anything that receives log entries. Implementations must be cheap and non-blocking.
public protocol LogSink: Sendable {
    func write(_ entry: LogEntry)
}
