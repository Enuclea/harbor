import Foundation
import HarborCore
import HarborPTY
import HarborSSH

/// What a tab runs.
public enum SessionKind: Sendable, Equatable {
    /// The user's shell on this Mac.
    case localShell
    /// An interactive SSH login.
    case ssh(HostProfile)
    /// A one-off program, e.g. `ssh-copy-id` or `brew install cloudflared`, run visibly
    /// so the user can watch and answer prompts.
    case command(CommandSpec, title: String)

    public var label: String {
        switch self {
        case .localShell: "local"
        case .ssh: "ssh"
        case .command: "command"
        }
    }

    public var host: HostProfile? {
        if case .ssh(let host) = self { return host }
        return nil
    }
}

public enum SessionState: Sendable, Equatable {
    case starting
    case running
    case exited(TerminationStatus)
    case failed(String)

    public var label: String {
        switch self {
        case .starting: "starting"
        case .running: "running"
        case .exited: "exited"
        case .failed: "failed"
        }
    }

    public var isRunning: Bool { self == .running }
}

/// One command observed through OSC 133 marks.
public struct CommandRecord: Sendable, Equatable {
    public let startedAt: Date
    public var finishedAt: Date?
    public var exitCode: Int32?
}

/// Where a newly opened session should appear.
public enum SessionPlacement: Sendable, Equatable {
    case newTab
    case newWindow
}

/// The text on a session's screen, provided by whatever renders it.
public struct ScreenSnapshot: Sendable, Equatable {
    public let lines: [String]
    public let scrollbackCount: Int
    public let cursorRow: Int?
    public let cursorColumn: Int?

    public init(lines: [String], scrollbackCount: Int, cursorRow: Int?, cursorColumn: Int?) {
        self.lines = lines
        self.scrollbackCount = scrollbackCount
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
    }
}

/// Implemented by the terminal view so automation can read exactly what the user sees.
@MainActor
public protocol ScreenReading: AnyObject {
    func screenSnapshot(scrollbackLines: Int) -> ScreenSnapshot
}

/// Implemented by the window layer: shows sessions as tabs/windows and reports their order.
@MainActor
public protocol SessionPresenting: AnyObject {
    func present(_ session: TerminalSession, placement: SessionPlacement)
    func focus(_ session: TerminalSession)
    func dismiss(_ session: TerminalSession)
    /// Sessions in visual order: windows front to back, tabs left to right.
    func orderedSessionIDs() -> [SessionID]
    func focusedSessionID() -> SessionID?
}
