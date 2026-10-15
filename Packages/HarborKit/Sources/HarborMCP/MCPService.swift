import Foundation
import HarborControl
import HarborCore
import HarborLogging
import os

/// Runs the MCP endpoint on Harbor's control socket. Each connection (one per running
/// `harbor-mcp` bridge) gets its own protocol state; requests on a connection are handled
/// concurrently so a long `run_command` doesn't block `list_tabs`.
public final class MCPService: Sendable {
    private let server: UnixSocketServer
    private let log = Log(.mcp)
    private let connections = OSAllocatedUnfairLock(initialState: 0)

    public init(socketPath: String, control: any TerminalControlling) {
        let toolbox = HarborToolbox(control: control)
        let connections = connections
        server = UnixSocketServer(path: socketPath) { connection in
            let handler = MCPConnectionHandler(toolbox: toolbox)
            let tracker = RequestTracker { connection.close() }
            connections.withLock { $0 += 1 }
            connection.onLine = { line in
                tracker.begin()
                Task {
                    if let response = await handler.handle(line) { connection.send(response) }
                    tracker.end()
                }
            }
            connection.onInputEnded = {
                connections.withLock { $0 -= 1 }
                tracker.inputEnded()
            }
        }
    }

    public var socketPath: String { server.path }

    /// Number of assistant bridges currently connected.
    public var connectionCount: Int { connections.withLock { $0 } }

    public func start() throws {
        try server.start()
    }

    public func stop() {
        server.stop()
    }
}

/// Closes a connection only after its in-flight requests have answered, so a client that
/// half-closes after sending (as scripts do) still gets every response.
private final class RequestTracker: Sendable {
    private struct State: Sendable {
        var inFlight = 0
        var inputEnded = false
        var closed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let close: @Sendable () -> Void

    init(close: @escaping @Sendable () -> Void) {
        self.close = close
    }

    func begin() {
        state.withLock { $0.inFlight += 1 }
    }

    func end() {
        let idle = state.withLock { state -> Bool in
            state.inFlight -= 1
            return Self.claimClose(&state)
        }
        if idle { close() }
    }

    func inputEnded() {
        let idle = state.withLock { state -> Bool in
            state.inputEnded = true
            return Self.claimClose(&state)
        }
        if idle { close() }
    }

    private static func claimClose(_ state: inout State) -> Bool {
        guard state.inputEnded, state.inFlight == 0, !state.closed else { return false }
        state.closed = true
        return true
    }
}
