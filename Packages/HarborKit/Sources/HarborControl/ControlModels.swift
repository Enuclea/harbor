import Foundation
import HarborCore

/// A tab as seen by automation clients.
public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// 1-based position in tab order — the friendliest way for an assistant to refer to a tab.
    public let index: Int
    public let title: String
    /// `local`, `ssh` or `command`.
    public let kind: String
    public let host: String?
    public let workingDirectory: String?
    public let foregroundProcess: String?
    /// `starting`, `running`, `exited` or `failed`.
    public let state: String
    public let exitCode: Int32?
    public let isFocused: Bool
    public let columns: Int
    public let rows: Int
    /// The shell that reported integration (`zsh`, `bash`, `fish`), if any. Needed for
    /// reliable command results.
    public let shellIntegration: String?
    public let isAtPrompt: Bool
    public let lastCommandExitCode: Int32?

    public init(id: String, index: Int, title: String, kind: String, host: String?, workingDirectory: String?,
                foregroundProcess: String?, state: String, exitCode: Int32?, isFocused: Bool, columns: Int, rows: Int,
                shellIntegration: String?, isAtPrompt: Bool, lastCommandExitCode: Int32?) {
        self.id = id
        self.index = index
        self.title = title
        self.kind = kind
        self.host = host
        self.workingDirectory = workingDirectory
        self.foregroundProcess = foregroundProcess
        self.state = state
        self.exitCode = exitCode
        self.isFocused = isFocused
        self.columns = columns
        self.rows = rows
        self.shellIntegration = shellIntegration
        self.isAtPrompt = isAtPrompt
        self.lastCommandExitCode = lastCommandExitCode
    }
}

public struct HostSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let destination: String
    public let tags: [String]
    public let isFavorite: Bool

    public init(_ host: HostProfile) {
        id = host.id.description
        name = host.name
        destination = host.destinationLabel
        tags = host.tags
        isFavorite = host.isFavorite
    }
}

/// Text currently on a tab's screen.
public struct ScreenContent: Codable, Sendable, Equatable {
    public let sessionID: String
    public let columns: Int
    public let rows: Int
    public let cursorRow: Int?
    public let cursorColumn: Int?
    /// Scrollback lines (oldest first) followed by the visible lines.
    public let lines: [String]
    public let scrollbackLineCount: Int

    public init(sessionID: String, columns: Int, rows: Int, cursorRow: Int?, cursorColumn: Int?, lines: [String], scrollbackLineCount: Int) {
        self.sessionID = sessionID
        self.columns = columns
        self.rows = rows
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.lines = lines
        self.scrollbackLineCount = scrollbackLineCount
    }

    public var text: String { lines.joined(separator: "\n") }
}

/// The result of running one command in a tab.
public struct CommandOutcome: Codable, Sendable, Equatable {
    public let output: String
    /// Nil when the shell has no integration, or the command didn't finish in time.
    public let exitCode: Int32?
    public let completed: Bool
    public let truncated: Bool
    public let durationMilliseconds: Int

    public init(output: String, exitCode: Int32?, completed: Bool, truncated: Bool, durationMilliseconds: Int) {
        self.output = output
        self.exitCode = exitCode
        self.completed = completed
        self.truncated = truncated
        self.durationMilliseconds = durationMilliseconds
    }
}

/// What to open.
public enum OpenSessionRequest: Sendable, Equatable {
    case localShell(workingDirectory: String?)
    /// A saved host, by id, name or fuzzy query.
    case savedHost(String)
    /// A typed destination like `user@host:2222`.
    case destination(String)
}

/// Who is asking. Used for policy decisions and the audit trail.
public struct ControlClient: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// An AI assistant over MCP.
        case assistant
        /// A signed-in browser over remote access.
        case web
    }

    public let kind: Kind
    public let name: String

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }

    public var description: String { "\(kind.rawValue):\(name)" }
}

/// Changes pushed to streaming clients.
public enum ControlEvent: Sendable, Equatable {
    case sessionOpened(String)
    case sessionClosed(String)
    case sessionUpdated(String)
}

public enum ControlError: Error, LocalizedError, Equatable {
    case sessionNotFound(String)
    case hostNotFound(String)
    case notPermitted(String)
    case declinedByUser
    case sessionNotRunning
    case invalidArgument(String)
    case busy(String)

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound(let reference): "No tab matches “\(reference)”. Use list_tabs to see open tabs."
        case .hostNotFound(let reference): "No saved host matches “\(reference)”. Use list_hosts to see saved hosts."
        case .notPermitted(let reason): reason
        case .declinedByUser: "The user declined this request."
        case .sessionNotRunning: "That tab's process has exited."
        case .invalidArgument(let reason): reason
        case .busy(let reason): reason
        }
    }
}
