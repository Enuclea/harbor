import Foundation
import HarborPTY

/// What a session is doing right now, for tab indicators and automation.
public enum SessionActivity: Sendable, Equatable {
    /// Launching, or an SSH tab that hasn't printed anything yet.
    case starting
    /// At a prompt (or quiet). Carries the last command's exit code when known.
    case idle(lastExitCode: Int32?)
    /// A command is running. `since` and `command` are known with shell integration.
    case busy(since: Date?, command: String?)
    /// Output is flowing but Harbor can't tell whether a command is running (e.g. SSH
    /// hosts without shell integration).
    case streaming
    case exited(TerminationStatus)
    case failed(String)

    /// Stable short name for APIs and the web dashboard.
    public var name: String {
        switch self {
        case .starting: "starting"
        case .idle: "idle"
        case .busy: "busy"
        case .streaming: "streaming"
        case .exited(let status): status.isClean ? "exited" : "failed"
        case .failed: "failed"
        }
    }
}

extension TerminalSession {
    public var activity: SessionActivity {
        switch state {
        case .starting:
            return .starting
        case .failed(let message):
            return .failed(message)
        case .exited(let status):
            return .exited(status)
        case .running:
            break
        }
        if shellIntegration != nil {
            if isAtPrompt { return .idle(lastExitCode: lastCommand?.exitCode) }
            if let command = lastCommand, command.finishedAt == nil {
                return .busy(since: command.startedAt, command: runningCommand)
            }
            return isStreamingOutput ? .streaming : .idle(lastExitCode: lastCommand?.exitCode)
        }
        switch kind {
        case .command:
            return .busy(since: createdAt, command: title)
        case .localShell:
            if let process = foregroundProcessName, !Self.isShell(process) { return .busy(since: nil, command: process) }
        case .ssh:
            if !hasOutput { return .starting }
        }
        return isStreamingOutput ? .streaming : .idle(lastExitCode: nil)
    }
}
