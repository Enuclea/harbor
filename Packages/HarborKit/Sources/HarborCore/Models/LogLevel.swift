import Foundation

/// Severity levels shared by the logging system and settings.
public enum LogLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case debug, info, notice, warning, error, fault

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .notice: 2
        case .warning: 3
        case .error: 4
        case .fault: 5
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }

    public var label: String { rawValue.capitalized }
}
