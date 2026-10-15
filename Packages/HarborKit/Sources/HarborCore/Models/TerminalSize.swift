import Foundation

/// A terminal grid size in character cells.
public struct TerminalSize: Hashable, Sendable, Codable, CustomStringConvertible {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }

    public static let standard = TerminalSize(columns: 100, rows: 30)

    public var description: String { "\(columns)×\(rows)" }
}
