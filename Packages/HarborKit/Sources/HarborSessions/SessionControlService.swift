import Foundation
import HarborControl
import HarborCore
import HarborLogging
import HarborSSH

/// Implements the automation contract on top of real sessions. Every call is checked
/// against `ControlPolicy`, may ask the user, and is written to the audit trail.
@MainActor
public final class SessionControlService: TerminalControlling, TerminalStreaming {
    private let manager: SessionManager
    private let hosts: HostLibrary
    private let settings: SettingsStore
    private let audit: AuditTrail
    public weak var approver: (any ApprovalRequesting)?

    private struct ApprovalKey: Hashable {
        let client: String
        let session: SessionID
    }

    private var rememberedApprovals = Set<ApprovalKey>()

    public init(manager: SessionManager, hosts: HostLibrary, settings: SettingsStore, audit: AuditTrail) {
        self.manager = manager
        self.hosts = hosts
        self.settings = settings
        self.audit = audit
    }

    // MARK: TerminalControlling

    public func listSessions() async -> [SessionSummary] {
        let focused = manager.presenter?.focusedSessionID()
        return orderedSessions().enumerated().map { summary(for: $1, index: $0 + 1, focused: focused) }
    }

    public func describeSession(_ reference: String) async throws -> SessionSummary {
        try summary(for: resolve(reference))
    }

    public func openSession(_ request: OpenSessionRequest, client: ControlClient) async throws -> SessionSummary {
        let (kind, directory, description) = try sessionKind(for: request)
        try await authorize(.openSession, client: client, session: nil, detail: description)
        let session = manager.open(kind, workingDirectory: directory)
        if client.kind == .assistant { session.noteAssistantActivity() }
        record(client, "open_session", session, detail: description, .allowed)
        return summary(for: session)
    }

    public func focusSession(_ reference: String, client: ControlClient) async throws -> SessionSummary {
        let session = try resolve(reference)
        try await authorize(.focusSession, client: client, session: session, detail: nil)
        manager.presenter?.focus(session)
        record(client, "focus_session", session, detail: nil, .allowed)
        return summary(for: session)
    }

    public func closeSession(_ reference: String, client: ControlClient) async throws {
        let session = try resolve(reference)
        try await authorize(.closeSession, client: client, session: session, detail: nil)
        record(client, "close_session", session, detail: nil, .allowed)
        manager.close(session)
    }

    public func sendInput(_ reference: String, text: String, client: ControlClient) async throws {
        let session = try resolve(reference)
        guard session.state.isRunning else { throw ControlError.sessionNotRunning }
        try await authorize(.sendInput, client: client, session: session, detail: text)
        session.noteAssistantActivity()
        if text.hasSuffix("\r"), text.filter({ $0 == "\r" || $0 == "\n" }).count == 1 {
            session.noteSubmittedCommand(String(text.dropLast()), fromAssistant: client.kind == .assistant)
        }
        session.send(text: text)
        record(client, "send_input", session, detail: text, .allowed)
    }

    public func readScreen(_ reference: String, scrollbackLines: Int, client: ControlClient) async throws -> ScreenContent {
        let session = try resolve(reference)
        try await authorize(.readScreen, client: client, session: session, detail: nil)
        let limit = max(0, min(scrollbackLines, 5_000))
        let snapshot = session.screen?.screenSnapshot(scrollbackLines: limit) ?? fallbackSnapshot(session, scrollbackLines: limit)
        record(client, "read_screen", session, detail: nil, .allowed)
        return ScreenContent(
            sessionID: session.id.description, columns: session.size.columns, rows: session.size.rows,
            cursorRow: snapshot.cursorRow, cursorColumn: snapshot.cursorColumn,
            lines: snapshot.lines, scrollbackLineCount: snapshot.scrollbackCount)
    }

    public func runCommand(_ reference: String, command: String, timeout: Duration, client: ControlClient) async throws -> CommandOutcome {
        let session = try resolve(reference)
        guard session.state.isRunning else { throw ControlError.sessionNotRunning }
        guard !command.contains("\n"), !command.contains("\r") else {
            throw ControlError.invalidArgument("run_command takes a single line. Use send_text for multi-line input.")
        }
        if session.shellIntegration != nil, !(await session.waitUntilAtPrompt(timeout: .seconds(1))) {
            throw ControlError.busy("A command is still running in that tab. Use read_screen to check on it, or send_keys ctrl+c.")
        }
        try await authorize(.sendInput, client: client, session: session, detail: command)
        session.noteAssistantActivity()
        session.noteSubmittedCommand(command, fromAssistant: client.kind == .assistant)
        let outcome = await session.run(command, timeout: timeout)
        record(client, "run_command", session, detail: command, .allowed)
        return outcome
    }

    public func listHosts() async -> [HostSummary] {
        hosts.hosts.map(HostSummary.init)
    }

    // MARK: TerminalStreaming

    public func attach(_ sessionID: String, client: ControlClient, onOutput: @escaping @Sendable (Data) -> Void) async throws -> SessionAttachment {
        let session = try resolve(sessionID)
        try await authorize(.readScreen, client: client, session: session, detail: nil)
        let (token, replay) = session.pipeline.attach(onOutput)
        let pipeline = session.pipeline
        record(client, "attach", session, detail: nil, .allowed)
        return SessionAttachment(replay: replay, size: session.size) { pipeline.detach(token) }
    }

    public func write(_ sessionID: String, data: Data, client: ControlClient) async throws {
        let session = try resolve(sessionID)
        guard session.state.isRunning else { throw ControlError.sessionNotRunning }
        try await authorize(.sendInput, client: client, session: session, detail: nil)
        session.send(data)
    }

    public func resize(_ sessionID: String, to size: TerminalSize, client: ControlClient) async {
        guard let session = try? resolve(sessionID),
              case .allow = ControlPolicy.decide(.sendInput, client: client, settings: settings.settings) else { return }
        session.resize(size)
    }

    public func events() async -> AsyncStream<ControlEvent> {
        manager.events()
    }

    // MARK: Authorization

    public func hasRememberedApproval(for sessionID: SessionID) -> Bool {
        rememberedApprovals.contains { $0.session == sessionID }
    }

    public func revokeApproval(for sessionID: SessionID) {
        rememberedApprovals = rememberedApprovals.filter { $0.session != sessionID }
    }

    private func authorize(_ action: ControlAction, client: ControlClient, session: TerminalSession?, detail: String?) async throws {
        switch ControlPolicy.decide(action, detail: detail, client: client, settings: settings.settings) {
        case .allow:
            return
        case .deny(let reason):
            record(client, "\(action)", session, detail: detail, .denied)
            throw ControlError.notPermitted(reason)
        case .ask:
            if let session, rememberedApprovals.contains(ApprovalKey(client: client.name, session: session.id)) { return }
            guard let approver else {
                throw ControlError.notPermitted("Harbor needs someone at the Mac to approve this, but no approval prompt is available.")
            }
            let canRemember = settings.settings.ai.inputPolicy == .askOncePerTab
            let decision = await approver.requestApproval(ApprovalRequest(
                client: client, sessionID: session?.id, sessionTitle: session?.title ?? "a new tab",
                action: action, detail: detail, canRemember: canRemember))
            switch decision {
            case .allowOnce:
                return
            case .allowForSession:
                if let session { rememberedApprovals.insert(ApprovalKey(client: client.name, session: session.id)) }
            case .deny:
                record(client, "\(action)", session, detail: detail, .denied)
                throw ControlError.declinedByUser
            }
        }
    }

    // MARK: Resolution

    /// Accepts an id, id prefix, 1-based index, exact title, or `current`.
    func resolve(_ reference: String) throws -> TerminalSession {
        let ordered = orderedSessions()
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || ["current", "active", "focused", "this"].contains(trimmed.lowercased()) {
            if let focused = manager.presenter?.focusedSessionID(), let session = manager.session(focused) { return session }
            if let first = ordered.first { return first }
            throw ControlError.sessionNotFound(reference)
        }
        if let index = Int(trimmed), ordered.indices.contains(index - 1) { return ordered[index - 1] }
        if let id = SessionID(string: trimmed), let session = manager.session(id) { return session }
        let lowered = trimmed.lowercased()
        if lowered.count >= 4 {
            let matches = ordered.filter { $0.id.description.hasPrefix(lowered) }
            if matches.count == 1 { return matches[0] }
        }
        let titled = ordered.filter { $0.title.lowercased() == lowered }
        if titled.count == 1 { return titled[0] }
        throw ControlError.sessionNotFound(reference)
    }

    private func orderedSessions() -> [TerminalSession] {
        let order = manager.presenter?.orderedSessionIDs() ?? []
        var result = order.compactMap(manager.session)
        result += manager.sessions.filter { session in !result.contains { $0 === session } }
        return result
    }

    private func sessionKind(for request: OpenSessionRequest) throws -> (SessionKind, String?, String) {
        switch request {
        case .localShell(let directory):
            return (.localShell, directory, "local shell" + (directory.map { " in \($0)" } ?? ""))
        case .savedHost(let reference):
            let host = try findHost(reference)
            return (.ssh(host), nil, "ssh to \(host.name)")
        case .destination(let destination):
            do {
                let host = try SSHDestination.parse(destination)
                try HostProfileValidator.validate(host)
                return (.ssh(host), nil, "ssh to \(host.destinationLabel)")
            } catch {
                throw ControlError.invalidArgument(error.localizedDescription)
            }
        }
    }

    private func findHost(_ reference: String) throws -> HostProfile {
        if let id = HostID(string: reference), let host = hosts.host(id: id) { return host }
        let lowered = reference.lowercased()
        if let exact = hosts.hosts.first(where: { $0.name.lowercased() == lowered || $0.hostname.lowercased() == lowered }) {
            return exact
        }
        let matches = hosts.search(reference)
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw ControlError.invalidArgument("“\(reference)” matches several hosts: \(matches.prefix(5).map(\.name).joined(separator: ", ")).")
        }
        throw ControlError.hostNotFound(reference)
    }

    // MARK: Helpers

    private func summary(for session: TerminalSession, index: Int? = nil, focused: SessionID? = nil) -> SessionSummary {
        let position = index ?? (orderedSessions().firstIndex { $0 === session }.map { $0 + 1 } ?? 0)
        let exitCode: Int32? = if case .exited(let status) = session.state { status.exitCode } else { nil }
        return SessionSummary(
            id: session.id.description, index: position, title: session.title, kind: session.kind.label,
            host: session.kind.host?.destinationLabel, workingDirectory: session.workingDirectory,
            foregroundProcess: session.foregroundProcessName, state: session.state.label, exitCode: exitCode,
            isFocused: (focused ?? manager.presenter?.focusedSessionID()) == session.id,
            columns: session.size.columns, rows: session.size.rows, shellIntegration: session.shellIntegration,
            isAtPrompt: session.isAtPrompt, lastCommandExitCode: session.lastCommand?.exitCode,
            activity: session.activity.name, runningCommand: session.runningCommand,
            systemProfile: session.systemProfile)
    }

    private func fallbackSnapshot(_ session: TerminalSession, scrollbackLines: Int) -> ScreenSnapshot {
        let text = ANSIStripper.plainText(from: session.pipeline.replay)
        let lines = text.components(separatedBy: "\n")
        let wanted = scrollbackLines + session.size.rows
        let tail = Array(lines.suffix(wanted))
        return ScreenSnapshot(lines: tail, scrollbackCount: max(0, tail.count - session.size.rows), cursorRow: nil, cursorColumn: nil)
    }

    private func record(_ client: ControlClient, _ action: String, _ session: TerminalSession?, detail: String?, _ outcome: AuditRecord.Outcome) {
        audit.record(AuditRecord(actor: client.description, action: action, target: session?.title, detail: detail, outcome: outcome))
    }
}
