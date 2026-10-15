import Foundation
import HarborCore

/// The automation surface of Harbor: everything an AI assistant (MCP) or a browser
/// (remote access) can do. Implementations enforce policy and audit every call.
///
/// `reference` arguments accept a tab id, an id prefix, a 1-based tab index, an exact
/// title, or `current` for the focused tab.
public protocol TerminalControlling: Sendable {
    func listSessions() async -> [SessionSummary]
    func describeSession(_ reference: String) async throws -> SessionSummary
    func openSession(_ request: OpenSessionRequest, client: ControlClient) async throws -> SessionSummary
    func focusSession(_ reference: String, client: ControlClient) async throws -> SessionSummary
    func closeSession(_ reference: String, client: ControlClient) async throws
    /// Types `text` into the tab exactly as given (include `\r` to press Return).
    func sendInput(_ reference: String, text: String, client: ControlClient) async throws
    func readScreen(_ reference: String, scrollbackLines: Int, client: ControlClient) async throws -> ScreenContent
    /// Types `command`, presses Return and waits for it to finish.
    func runCommand(_ reference: String, command: String, timeout: Duration, client: ControlClient) async throws -> CommandOutcome
    func listHosts() async -> [HostSummary]
}

/// A live view of one session's byte stream, for the web terminal.
public struct SessionAttachment: Sendable {
    /// Recent output to replay so the client's screen matches before live data arrives.
    public let replay: Data
    public let size: TerminalSize
    public let detach: @Sendable () -> Void

    public init(replay: Data, size: TerminalSize, detach: @escaping @Sendable () -> Void) {
        self.replay = replay
        self.size = size
        self.detach = detach
    }
}

/// Raw streaming access, used by the web remote in addition to `TerminalControlling`.
public protocol TerminalStreaming: Sendable {
    func attach(_ sessionID: String, client: ControlClient, onOutput: @escaping @Sendable (Data) -> Void) async throws -> SessionAttachment
    func write(_ sessionID: String, data: Data, client: ControlClient) async throws
    func resize(_ sessionID: String, to size: TerminalSize, client: ControlClient) async
    func events() async -> AsyncStream<ControlEvent>
}
