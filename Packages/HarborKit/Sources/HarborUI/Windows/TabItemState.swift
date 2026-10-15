import Foundation
import HarborCore
import HarborSessions

/// What a tab's status indicator shows, in priority order.
enum TabStatus: Equatable {
    case starting
    case idle
    case idleAfterFailure(Int32)
    case busy
    case streaming
    /// Output arrived in a background tab.
    case newOutput
    /// The bell rang in a background tab.
    case bell
    case exited
    case failed

    var label: String {
        switch self {
        case .starting: "Starting"
        case .idle: "Idle"
        case .idleAfterFailure(let code): "Idle — last command exited \(code)"
        case .busy: "Running"
        case .streaming: "Producing output"
        case .newOutput: "New output"
        case .bell: "Bell"
        case .exited: "Exited"
        case .failed: "Failed"
        }
    }
}

/// Shell integration the tab's context menu offers to put on an SSH host.
enum IntegrationOffer: Equatable {
    /// The host isn't reporting through shell integration.
    case install
    /// The host runs an older version of it.
    case update
}

/// A value snapshot of one tab, so the strip renders from plain data (and can be
/// previewed or snapshot-tested without live sessions).
///
/// Line 1 says *where* (`user@host` for SSH, the folder for local tabs); line 2 says
/// *what* — the running or last command — so a glance across tabs shows what an
/// assistant is doing on each host.
struct TabItemState: Identifiable, Equatable {
    let id: SessionID
    let title: String
    let subtitle: String?
    /// Line 2 is a command line (drawn monospaced) rather than a description.
    let subtitleIsCommand: Bool
    /// Exit code shown after the last command when it failed.
    let failedExitCode: Int32?
    /// The command on line 2 was typed by an AI assistant.
    let commandByAssistant: Bool
    let status: TabStatus
    let hostColor: HostColor
    let isSelected: Bool
    let assistantActive: Bool
    /// When the running command started, for the elapsed-time label.
    let busySince: Date?
    let tooltip: String
    let integrationOffer: IntegrationOffer?
    /// For SSH tabs: whether the destination is in the host library (nil for local tabs).
    let hostSaved: Bool?

    init(id: SessionID, title: String, subtitle: String? = nil, subtitleIsCommand: Bool = false,
         failedExitCode: Int32? = nil, commandByAssistant: Bool = false, status: TabStatus, hostColor: HostColor = .none,
         isSelected: Bool, assistantActive: Bool = false, busySince: Date? = nil, tooltip: String = "",
         integrationOffer: IntegrationOffer? = nil, hostSaved: Bool? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.subtitleIsCommand = subtitleIsCommand
        self.failedExitCode = failedExitCode
        self.commandByAssistant = commandByAssistant
        self.status = status
        self.hostColor = hostColor
        self.isSelected = isSelected
        self.assistantActive = assistantActive
        self.busySince = busySince
        self.tooltip = tooltip.isEmpty ? [title, subtitle].compactMap { $0 }.joined(separator: "\n") : tooltip
        self.integrationOffer = integrationOffer
        self.hostSaved = hostSaved
    }

    /// - Parameter savedHost: The library's current copy of the tab's host, so edits (name,
    ///   colour) show without reconnecting. Nil when the destination isn't saved.
    @MainActor
    init(session: TerminalSession, isSelected: Bool, savedHost: HostProfile? = nil, now: Date = Date()) {
        let activity = session.activity
        let status = Self.status(for: session, activity: activity, isSelected: isSelected)
        let busySince: Date? = if case .busy(let since, _) = activity { since } else { nil }
        let line = Self.secondLine(for: session, host: savedHost, activity: activity)
        let assistantActive = session.assistantActivityAt.map { now.timeIntervalSince($0) < 30 } ?? false
        let title = Self.firstLine(for: session, host: savedHost)

        var tooltip = [title]
        if case .ssh(let host) = session.kind { tooltip.append("SSH · \(host.destinationLabel)") }
        if let directory = session.workingDirectory { tooltip.append((directory as NSString).abbreviatingWithTildeInPath) }
        if let text = line.text { tooltip.append(line.isCommand ? "\(status == .busy ? "Running" : "Last command"): \(text)" : text) }
        if let code = line.failedExitCode { tooltip.append("Exited with status \(code)") }
        tooltip.append(status.label)
        if assistantActive { tooltip.append("An AI assistant is working in this tab") }

        self.init(
            id: session.id, title: title, subtitle: line.text, subtitleIsCommand: line.isCommand,
            failedExitCode: line.failedExitCode, commandByAssistant: line.byAssistant, status: status,
            hostColor: (savedHost ?? session.kind.host)?.color ?? .none, isSelected: isSelected, assistantActive: assistantActive,
            busySince: busySince, tooltip: tooltip.joined(separator: "\n"),
            integrationOffer: Self.integrationOffer(for: session),
            hostSaved: session.kind.host == nil ? nil : savedHost != nil)
    }

    // MARK: Derivation

    @MainActor
    private static func integrationOffer(for session: TerminalSession) -> IntegrationOffer? {
        guard session.kind.host != nil, session.state.isRunning else { return nil }
        guard session.shellIntegration != nil else { return .install }
        if let version = session.shellIntegrationVersion, version < AppIdentity.shellIntegrationVersion { return .update }
        return nil
    }

    @MainActor
    private static func status(for session: TerminalSession, activity: SessionActivity, isSelected: Bool) -> TabStatus {
        switch activity {
        case .failed: return .failed
        case .exited(let termination): return termination.isClean ? .exited : .failed
        default: break
        }
        if session.bellPending && !isSelected { return .bell }
        switch activity {
        case .busy: return .busy
        case .streaming: return .streaming
        default: break
        }
        if session.hasUnseenActivity && !isSelected { return .newOutput }
        switch activity {
        case .starting: return .starting
        case .idle(let code?) where code != 0: return .idleAfterFailure(code)
        default: return .idle
        }
    }

    /// `user@host` for SSH (`user@name` when the host shows its name in the prompt), the
    /// folder (or custom title) for local tabs. `host` overrides the session's copy of its
    /// host (pass the library's current version).
    @MainActor
    static func firstLine(for session: TerminalSession, host override: HostProfile? = nil) -> String {
        if let custom = session.customTitle, !custom.isEmpty { return custom }
        switch session.kind {
        case .ssh(let original):
            let host = override ?? original
            let name = host.name.trimmingCharacters(in: .whitespaces)
            if host.showsNameInPrompt, !name.isEmpty {
                let user = host.user.flatMap { $0.isEmpty ? nil : $0 }
                    ?? session.programTitle.flatMap(userAtHost).map { String($0.prefix { $0 != "@" }) }
                return user.map { "\($0)@\(name)" } ?? name
            }
            if let user = host.user, !user.isEmpty { return "\(user)@\(host.hostname)" }
            if let program = session.programTitle, let destination = userAtHost(in: program) { return destination }
            return host.name
        case .command(_, let title):
            return title
        case .localShell:
            return session.directoryDisplayName ?? "Terminal"
        }
    }

    private struct SecondLine {
        var text: String?
        var isCommand = false
        var failedExitCode: Int32?
        var byAssistant = false
    }

    @MainActor
    private static func secondLine(for session: TerminalSession, host override: HostProfile?, activity: SessionActivity) -> SecondLine {
        switch activity {
        case .exited(let termination):
            return SecondLine(text: termination.isClean ? "Process completed" : "Process \(termination)")
        case .failed(let message):
            return SecondLine(text: message)
        default:
            break
        }
        if let running = session.runningCommand {
            return SecondLine(text: running, isCommand: true, byAssistant: session.lastCommandFromAssistant)
        }
        if let last = session.lastCommandLine {
            let code = session.lastCommand?.exitCode.flatMap { $0 == 0 ? nil : $0 }
            return SecondLine(text: last, isCommand: true, failedExitCode: code, byAssistant: session.lastCommandFromAssistant)
        }
        switch session.kind {
        case .ssh(let original):
            let host = override ?? original
            if case .starting = activity { return SecondLine(text: "Connecting…") }
            if let program = session.programTitle, let colon = program.firstIndex(of: ":") {
                let path = program[program.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !path.isEmpty { return SecondLine(text: path) }
            }
            let showsName = host.showsNameInPrompt || host.name == firstLine(for: session, host: host)
            return SecondLine(text: showsName ? host.destinationLabel : host.name)
        case .localShell:
            if case .busy(_, let process?) = activity { return SecondLine(text: process, isCommand: true) }
            return SecondLine(text: session.workingDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath })
        case .command:
            return SecondLine(text: nil)
        }
    }

    /// Pulls `user@host` out of a title like `dan@web-1: ~/app`.
    static func userAtHost(in title: String) -> String? {
        let candidate = title.split(whereSeparator: { $0 == ":" || $0 == " " }).first.map(String.init) ?? ""
        guard candidate.contains("@"), !candidate.hasPrefix("@"), !candidate.hasSuffix("@") else { return nil }
        return candidate
    }
}
