import Foundation
import HarborControl
import HarborCore
@testable import HarborMCP
import Testing

/// A canned `TerminalControlling` so protocol tests don't need real sessions.
private actor FakeControl: TerminalControlling {
    var typed: [String] = []
    var lastClient: ControlClient?

    let tab = SessionSummary(
        id: "4f2a9c1e-0000-0000-0000-000000000000", index: 1, title: "zsh", kind: "local", host: nil,
        workingDirectory: "/Users/me", foregroundProcess: "zsh", state: "running", exitCode: nil, isFocused: true,
        columns: 80, rows: 24, shellIntegration: "zsh", isAtPrompt: true, lastCommandExitCode: 0)

    func listSessions() async -> [SessionSummary] { [tab] }
    func describeSession(_ reference: String) async throws -> SessionSummary {
        guard reference == "1" || reference == "current" else { throw ControlError.sessionNotFound(reference) }
        return tab
    }
    func openSession(_ request: OpenSessionRequest, client: ControlClient) async throws -> SessionSummary { tab }
    func focusSession(_ reference: String, client: ControlClient) async throws -> SessionSummary { tab }
    func closeSession(_ reference: String, client: ControlClient) async throws {
        throw ControlError.notPermitted("Closing tabs is turned off for assistants.")
    }
    func sendInput(_ reference: String, text: String, client: ControlClient) async throws {
        typed.append(text)
        lastClient = client
    }
    func readScreen(_ reference: String, scrollbackLines: Int, client: ControlClient) async throws -> ScreenContent {
        ScreenContent(sessionID: tab.id, columns: 80, rows: 24, cursorRow: 1, cursorColumn: 2, lines: ["$ ls", "README.md"], scrollbackLineCount: 0)
    }
    func runCommand(_ reference: String, command: String, timeout: Duration, client: ControlClient) async throws -> CommandOutcome {
        CommandOutcome(output: "ran \(command)", exitCode: command == "false" ? 1 : 0, completed: true, truncated: false, durationMilliseconds: 5)
    }
    func listHosts() async -> [HostSummary] { [HostSummary(HostProfile(name: "prod", hostname: "prod.example.com"))] }
}

private func request(_ method: String, id: Int? = 1, params: JSONValue? = nil) -> Data {
    var object: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
    if let id { object["id"] = .number(Double(id)) }
    if let params { object["params"] = params }
    return try! JSONEncoder().encode(JSONValue.object(object))
}

private func decode(_ data: Data?) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: try #require(data))
}

@Suite("MCP protocol")
struct MCPProtocolTests {
    @Test func initializeNegotiatesVersionAndNamesClient() async throws {
        let control = FakeControl()
        let handler = MCPConnectionHandler(toolbox: HarborToolbox(control: control))
        let response = try decode(await handler.handle(request("initialize", params: [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "Claude Desktop", "version": "1"],
        ])))
        #expect(response["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(response["result"]?["serverInfo"]?["name"]?.stringValue == "harbor")
        #expect(response["result"]?["capabilities"]?["tools"] != nil)

        _ = await handler.handle(request("tools/call", id: 2, params: ["name": "send_text", "arguments": ["text": "ls", "press_enter": true]]))
        #expect(await control.typed == ["ls\r"])
        #expect(await control.lastClient == ControlClient(kind: .assistant, name: "Claude Desktop"))
    }

    @Test func unknownVersionFallsBackToLatest() async throws {
        let handler = MCPConnectionHandler(toolbox: HarborToolbox(control: FakeControl()))
        let response = try decode(await handler.handle(request("initialize", params: ["protocolVersion": "1999-01-01"])))
        #expect(response["result"]?["protocolVersion"]?.stringValue == MCPConnectionHandler.supportedProtocolVersions[0])
    }

    @Test func listsToolsWithSchemasAndAnnotations() async throws {
        let handler = MCPConnectionHandler(toolbox: HarborToolbox(control: FakeControl()))
        let response = try decode(await handler.handle(request("tools/list")))
        let tools = try #require(response["result"]?["tools"]?.arrayValue)
        let names = Set(tools.compactMap { $0["name"]?.stringValue })
        #expect(names.isSuperset(of: ["list_tabs", "read_screen", "run_command", "send_text", "send_keys", "connect_host", "wait_for_text"]))
        for tool in tools {
            #expect(tool["inputSchema"]?["type"]?.stringValue == "object")
            #expect(tool["annotations"]?["readOnlyHint"]?.boolValue != nil)
        }
        let readScreen = try #require(tools.first { $0["name"]?.stringValue == "read_screen" })
        #expect(readScreen["annotations"]?["readOnlyHint"]?.boolValue == true)
    }

    @Test func runCommandReportsExitCodes() async throws {
        let handler = MCPConnectionHandler(toolbox: HarborToolbox(control: FakeControl()))
        let ok = try decode(await handler.handle(request("tools/call", params: ["name": "run_command", "arguments": ["command": "true"]])))
        #expect(ok["result"]?["isError"]?.boolValue == false)
        #expect(ok["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("[exit code: 0]") == true)
        let failed = try decode(await handler.handle(request("tools/call", params: ["name": "run_command", "arguments": ["command": "false"]])))
        #expect(failed["result"]?["isError"]?.boolValue == true)
    }

    @Test func toolFailuresAreResultsNotProtocolErrors() async throws {
        let handler = MCPConnectionHandler(toolbox: HarborToolbox(control: FakeControl()))
        let response = try decode(await handler.handle(request("tools/call", params: ["name": "close_tab", "arguments": ["tab": "1"]])))
        #expect(response["error"] == nil)
        #expect(response["result"]?["isError"]?.boolValue == true)
        #expect(response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("turned off") == true)
    }

    @Test func protocolMisuseIsAnError() async throws {
        let handler = MCPConnectionHandler(toolbox: HarborToolbox(control: FakeControl()))
        let unknownTool = try decode(await handler.handle(request("tools/call", params: ["name": "rm_rf"])))
        #expect(unknownTool["error"]?["code"]?.intValue == JSONRPCError.invalidParams)
        let unknownMethod = try decode(await handler.handle(request("does/not/exist")))
        #expect(unknownMethod["error"]?["code"]?.intValue == JSONRPCError.methodNotFound)
        let garbage = try decode(await handler.handle(Data("{nope".utf8)))
        #expect(garbage["error"]?["code"]?.intValue == JSONRPCError.parseError)
        #expect(await handler.handle(request("notifications/initialized", id: nil)) == nil)
    }

    @Test func badKeyNamesExplainThemselves() async throws {
        let handler = MCPConnectionHandler(toolbox: HarborToolbox(control: FakeControl()))
        let response = try decode(await handler.handle(request("tools/call", params: ["name": "send_keys", "arguments": ["keys": ["hyper+x"]]])))
        #expect(response["result"]?["isError"]?.boolValue == true)
    }
}

@Suite("MCP transport", .serialized)
struct MCPTransportTests {
    private func socketPath() -> String { "/tmp/hb-test-\(UUID().uuidString.prefix(8)).sock" }

    @Test func servesOverUnixSocketAndRefusesSecondServer() async throws {
        let path = socketPath()
        let service = MCPService(socketPath: path, control: FakeControl())
        try service.start()
        defer { service.stop() }
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(throws: UnixSocketError.self) { try MCPService(socketPath: path, control: FakeControl()).start() }
    }

    @Test func bridgeBinaryRelaysAFullExchange() async throws {
        let path = socketPath()
        let service = MCPService(socketPath: path, control: FakeControl())
        try service.start()
        defer { service.stop() }

        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = packageRoot.appending(path: ".build/debug/harbor-mcp")
        try #require(FileManager.default.isExecutableFile(atPath: bridge.path), "build harbor-mcp first")

        let input = [
            request("initialize", id: 1, params: ["protocolVersion": "2025-06-18", "clientInfo": ["name": "bridge-test"]]),
            request("notifications/initialized", id: nil),
            request("tools/call", id: 2, params: ["name": "read_screen", "arguments": [:]]),
        ].map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"

        let result = try await ProcessRunner.run(bridge.path, ["--socket", path], input: Data(input.utf8), timeout: .seconds(10))
        let lines = result.output.split(separator: "\n").map { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        #expect(lines.count == 2, "\(result.output) \(result.errorOutput)")
        #expect(lines.first??["result"]?["serverInfo"]?["name"]?.stringValue == "harbor")
        #expect(lines.last??["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("README.md") == true)
    }
}

@Suite("Client registration")
struct MCPClientRegistryTests {
    @Test func editsOnlyHarborsEntryAndBacksUp() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "harbor-mcp-home-\(UUID())")
        let configDirectory = home.appending(path: "Library/Application Support/Claude")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = configDirectory.appending(path: "claude_desktop_config.json")
        try Data(#"{"mcpServers":{"other":{"command":"/usr/bin/other"}},"theme":"dark"}"#.utf8).write(to: config)

        let registry = MCPClientRegistry(bridgePath: "/Applications/Harbor.app/Contents/MacOS/harbor-mcp", home: home)
        try await registry.register(.claudeDesktop)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
        let servers = written?["mcpServers"] as? [String: Any]
        #expect(servers?["other"] != nil)
        #expect((servers?["harbor"] as? [String: Any])?["command"] as? String == "/Applications/Harbor.app/Contents/MacOS/harbor-mcp")
        #expect(written?["theme"] as? String == "dark")
        #expect(FileManager.default.fileExists(atPath: config.path + ".harbor-backup"))
        #expect(await registry.status(for: .claudeDesktop).isRegistered)

        try await registry.unregister(.claudeDesktop)
        #expect(!(await registry.status(for: .claudeDesktop).isRegistered))
    }

    @Test func refusesToClobberInvalidJSON() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "harbor-mcp-home-\(UUID())")
        try FileManager.default.createDirectory(at: home.appending(path: ".cursor"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("{ broken".utf8).write(to: home.appending(path: ".cursor/mcp.json"))
        let registry = MCPClientRegistry(bridgePath: "/x/harbor-mcp", home: home)
        await #expect(throws: MCPClientRegistry.RegistrationError.self) { try await registry.register(.cursor) }
        #expect(try String(contentsOf: home.appending(path: ".cursor/mcp.json"), encoding: .utf8) == "{ broken")
    }

    @Test func codexTableIsReplacedNotDuplicated() {
        let toml = "model = \"o3\"\n\n[mcp_servers.harbor]\ncommand = \"/old\"\nargs = []\n\n[other]\nx = 1\n"
        let stripped = MCPClientRegistry.removingTOMLTable("mcp_servers.harbor", from: toml)
        #expect(!stripped.contains("/old"))
        #expect(stripped.contains("[other]"))
        #expect(stripped.contains("model = \"o3\""))
    }
}
