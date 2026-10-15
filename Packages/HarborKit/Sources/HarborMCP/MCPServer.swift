import Foundation
import HarborControl
import HarborCore
import HarborLogging

/// The Model Context Protocol endpoint for one client connection.
///
/// Handles the lifecycle (`initialize`, `ping`), tool discovery and tool calls. Tool
/// failures are returned as `isError` results, as MCP specifies, so the model can recover;
/// only protocol misuse becomes a JSON-RPC error.
public actor MCPConnectionHandler {
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let toolbox: HarborToolbox
    private let log = Log(.mcp)
    private var client = ControlClient(kind: .assistant, name: "MCP client")
    private(set) var negotiatedVersion: String?

    public init(toolbox: HarborToolbox) {
        self.toolbox = toolbox
    }

    /// Handles one JSON-RPC line and returns the response line, or nil for notifications.
    public func handle(_ line: Data) async -> Data? {
        let request: JSONRPCRequest
        do {
            request = try JSONDecoder().decode(JSONRPCRequest.self, from: line)
        } catch {
            if (try? JSONSerialization.jsonObject(with: line)) is [Any] {
                return JSONRPCResponse.failure(nil, JSONRPCError(code: JSONRPCError.invalidRequest, message: "Batching is not supported.")).encodedLine()
            }
            return JSONRPCResponse.failure(nil, JSONRPCError(code: JSONRPCError.parseError, message: "Invalid JSON.")).encodedLine()
        }
        guard request.jsonrpc == "2.0" else {
            return JSONRPCResponse.failure(request.id, JSONRPCError(code: JSONRPCError.invalidRequest, message: "jsonrpc must be \"2.0\".")).encodedLine()
        }
        if request.isNotification {
            handleNotification(request)
            return nil
        }
        do {
            return JSONRPCResponse.success(request.id, try await dispatch(request)).encodedLine()
        } catch let error as JSONRPCError {
            return JSONRPCResponse.failure(request.id, error).encodedLine()
        } catch {
            return JSONRPCResponse.failure(request.id, JSONRPCError(code: JSONRPCError.internalError, message: error.localizedDescription)).encodedLine()
        }
    }

    private func dispatch(_ request: JSONRPCRequest) async throws -> JSONValue {
        switch request.method {
        case "initialize": return initialize(request.params)
        case "ping": return [:]
        case "tools/list": return ["tools": .array(toolbox.tools.map(\.listing))]
        case "tools/call": return try await callTool(request.params)
        case "resources/list": return ["resources": []]
        case "prompts/list": return ["prompts": []]
        case "logging/setLevel": return [:]
        default: throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "Method not found: \(request.method)")
        }
    }

    private func initialize(_ params: JSONValue?) -> JSONValue {
        let requested = params?["protocolVersion"]?.stringValue
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.supportedProtocolVersions[0]
        negotiatedVersion = version
        if let name = params?["clientInfo"]?["name"]?.stringValue, !name.isEmpty {
            client = ControlClient(kind: .assistant, name: name)
        }
        log.notice("MCP client connected: \(client.name)", ["protocol": version])
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "harbor", "title": .string("\(AppIdentity.name) Terminal"), "version": .string(AppIdentity.version)],
            "instructions": .string(Self.instructions),
        ]
    }

    private func callTool(_ params: JSONValue?) async throws -> JSONValue {
        guard let name = params?["name"]?.stringValue else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "tools/call requires a tool name.")
        }
        guard let tool = toolbox.tool(named: name) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Unknown tool: \(name)")
        }
        log.info("tool \(name) called by \(client.name)")
        do {
            return try await tool.handler(MCPArguments(params?["arguments"]), client).json
        } catch {
            return MCPToolResult.error(error.localizedDescription).json
        }
    }

    private func handleNotification(_ request: JSONRPCRequest) {
        if request.method == "notifications/initialized" {
            log.debug("client \(client.name) initialized")
        }
    }

    static let instructions = """
        Harbor is the user's macOS terminal. Each tab is a local shell or an SSH session.
        Refer to tabs by the index from list_tabs, by id, or omit `tab` for the focused tab.
        Prefer run_command for shell commands: it waits for completion and returns output and exit code.
        For interactive programs (vim, top, installers, password prompts) use send_text / send_keys and read_screen.
        Typing may require the user's approval — if declined, don't retry; explain what you wanted to do.
        Never type passwords or secrets on the user's behalf.
        """
}
