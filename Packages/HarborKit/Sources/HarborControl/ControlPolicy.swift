import Foundation
import HarborCore

/// Something a client wants to do.
public enum ControlAction: Sendable, Equatable {
    case readScreen
    case sendInput
    case openSession
    case closeSession
    case focusSession

    public var verb: String {
        switch self {
        case .readScreen: "read the screen of"
        case .sendInput: "type into"
        case .openSession: "open"
        case .closeSession: "close"
        case .focusSession: "switch to"
        }
    }
}

public enum PolicyDecision: Sendable, Equatable {
    case allow
    case ask
    case deny(String)
}

/// Pure policy: maps settings + client + action to a decision. The service layer turns
/// `.ask` into a prompt and remembers "allow for this tab" answers.
public enum ControlPolicy {
    public static func decide(_ action: ControlAction, detail: String? = nil, client: ControlClient, settings: AppSettings) -> PolicyDecision {
        switch client.kind {
        case .web:
            return decideForBrowser(action, settings.remote)
        case .assistant:
            return decideForAssistant(action, detail: detail, settings.ai)
        }
    }

    /// True when `rawCommand` is a single command starting with an allowed read-only prefix
    /// and contains no shell chaining, redirection, command substitution, or destructive flags.
    public static func isSafeReadOnlyCommand(_ rawCommand: String, allowedPrefixes: [String]) -> Bool {
        var command = rawCommand
        if command.hasSuffix("\r") { command.removeLast() }
        command = command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return false }

        // Reject multi-line, pipes, redirection, backgrounding, or subshells.
        let forbiddenSubstrings = ["\n", "\r", ";", "|", "&", ">", "<", "`", "$(", "${"]
        if forbiddenSubstrings.contains(where: { command.contains($0) }) {
            return false
        }

        // Normalize consecutive spaces for prefix matching.
        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { return false }
        let normalized = tokens.joined(separator: " ")

        // Reject destructive find flags even if "find" is in the prefix list.
        if tokens.first == "find" {
            let dangerousFindFlags: Set<String> = ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fls"]
            if tokens.contains(where: { dangerousFindFlags.contains($0) }) { return false }
        }

        for rawPrefix in allowedPrefixes {
            let prefix = rawPrefix.trimmingCharacters(in: .whitespaces)
            guard !prefix.isEmpty else { continue }
            if normalized == prefix || normalized.hasPrefix(prefix + " ") {
                return true
            }
        }
        return false
    }

    /// A signed-in browser *is* the user, so the only limits are the remote-access switches.
    private static func decideForBrowser(_ action: ControlAction, _ remote: RemoteAccessSettings) -> PolicyDecision {
        guard remote.enabled else { return .deny("Remote access is turned off.") }
        switch action {
        case .sendInput where !remote.allowInput:
            return .deny("Remote access is read-only. Enable typing in Harbor ▸ Settings ▸ Remote Access.")
        case .openSession where !remote.allowOpeningSessions:
            return .deny("Opening tabs remotely is turned off.")
        default:
            return .allow
        }
    }

    private static func decideForAssistant(_ action: ControlAction, detail: String?, _ ai: AIControlSettings) -> PolicyDecision {
        guard ai.mcpEnabled else { return .deny("AI assistant access is turned off in Harbor ▸ Settings ▸ AI & MCP.") }
        switch action {
        case .readScreen:
            return ai.allowScreenReading ? .allow : .deny("Reading terminal contents is turned off for assistants.")
        case .focusSession:
            return .allow
        case .openSession:
            return ai.allowOpeningTabs ? .allow : .deny("Opening tabs is turned off for assistants.")
        case .closeSession:
            return ai.allowClosingTabs ? .allow : .deny("Closing tabs is turned off for assistants.")
        case .sendInput:
            switch ai.inputPolicy {
            case .deny:
                return .deny("Typing into terminals is turned off for assistants.")
            case .askEveryTime, .askOncePerTab:
                if ai.autoAllowReadOnlyCommands, let detail,
                   isSafeReadOnlyCommand(detail, allowedPrefixes: ai.allowedCommandPrefixes) {
                    return .allow
                }
                return .ask
            case .allow:
                return .allow
            }
        }
    }
}

/// A question for the person at the Mac.
public struct ApprovalRequest: Sendable, Equatable {
    public let client: ControlClient
    public let sessionID: SessionID?
    public let sessionTitle: String
    public let action: ControlAction
    /// What exactly will happen, e.g. the command about to be typed.
    public let detail: String?
    /// Whether "Allow for this tab" should be offered.
    public let canRemember: Bool

    public init(client: ControlClient, sessionID: SessionID?, sessionTitle: String, action: ControlAction, detail: String?, canRemember: Bool) {
        self.client = client
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.action = action
        self.detail = detail
        self.canRemember = canRemember
    }
}

public enum ApprovalDecision: Sendable, Equatable {
    case allowOnce, allowForSession, deny
}

/// Presents approval prompts. Implemented by the UI.
@MainActor
public protocol ApprovalRequesting: AnyObject {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision
}
