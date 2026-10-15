import Foundation
import HarborCore
import HarborLogging

/// AI apps Harbor can register itself with.
public enum MCPClientApp: String, CaseIterable, Sendable, Identifiable {
    case claudeDesktop, claudeCode, cursor, codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeDesktop: "Claude Desktop"
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        case .codex: "Codex CLI"
        }
    }
}

public struct MCPClientStatus: Sendable, Equatable {
    public let app: MCPClientApp
    public let isInstalled: Bool
    public let isRegistered: Bool
    /// Registered, but pointing at a different copy of Harbor (e.g. an old location).
    public let isStale: Bool
}

/// Adds Harbor's `harbor-mcp` bridge to AI apps' MCP configuration. Config files are
/// edited surgically (only the `harbor` entry) and backed up once before the first edit.
public struct MCPClientRegistry: Sendable {
    public static let serverName = "harbor"

    public let bridgePath: String
    public let home: URL
    private let log = Log(.mcp)

    public init(bridgePath: String, home: URL) {
        self.bridgePath = bridgePath
        self.home = home
    }

    /// JSON for apps Harbor doesn't know, to paste into any MCP client config.
    public var genericSnippet: String {
        """
        {
          "mcpServers": {
            "\(Self.serverName)": { "command": "\(bridgePath)", "args": [] }
          }
        }
        """
    }

    public func status() async -> [MCPClientStatus] {
        var statuses: [MCPClientStatus] = []
        for app in MCPClientApp.allCases {
            statuses.append(await status(for: app))
        }
        return statuses
    }

    public func status(for app: MCPClientApp) async -> MCPClientStatus {
        switch app {
        case .claudeDesktop, .cursor:
            let url = jsonConfigURL(app)
            let installed = FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path)
            let command = (readJSON(url)?["mcpServers"] as? [String: Any])?[Self.serverName]
                .flatMap { ($0 as? [String: Any])?["command"] as? String }
            return MCPClientStatus(app: app, isInstalled: installed, isRegistered: command != nil, isStale: command.map { $0 != bridgePath } ?? false)
        case .codex:
            let url = home.appending(path: ".codex/config.toml")
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let installed = FileManager.default.fileExists(atPath: home.appending(path: ".codex").path)
            let registered = text.contains("[mcp_servers.\(Self.serverName)]")
            return MCPClientStatus(app: app, isInstalled: installed, isRegistered: registered,
                                   isStale: registered && !text.contains(bridgePath))
        case .claudeCode:
            guard let claude = claudeCLI else { return MCPClientStatus(app: app, isInstalled: false, isRegistered: false, isStale: false) }
            let result = try? await ProcessRunner.run(claude, ["mcp", "get", Self.serverName], timeout: .seconds(10))
            let registered = result?.succeeded ?? false
            return MCPClientStatus(app: app, isInstalled: true, isRegistered: registered,
                                   isStale: registered && !(result?.output.contains(bridgePath) ?? true))
        }
    }

    /// Registers (or re-points) Harbor in `app`.
    public func register(_ app: MCPClientApp) async throws {
        switch app {
        case .claudeDesktop, .cursor:
            try updateJSONConfig(jsonConfigURL(app)) { servers in
                servers[Self.serverName] = ["command": bridgePath, "args": [String]()]
            }
        case .codex:
            try registerCodex()
        case .claudeCode:
            guard let claude = claudeCLI else { throw RegistrationError.notInstalled(app.displayName) }
            _ = try? await ProcessRunner.run(claude, ["mcp", "remove", "--scope", "user", Self.serverName], timeout: .seconds(15))
            let result = try await ProcessRunner.run(
                claude, ["mcp", "add", "--scope", "user", Self.serverName, "--", bridgePath], timeout: .seconds(30))
            guard result.succeeded else { throw RegistrationError.toolFailed(result.errorOutput + result.output) }
        }
        log.notice("registered MCP server with \(app.displayName)")
    }

    public func unregister(_ app: MCPClientApp) async throws {
        switch app {
        case .claudeDesktop, .cursor:
            try updateJSONConfig(jsonConfigURL(app)) { servers in servers.removeValue(forKey: Self.serverName) }
        case .codex:
            let url = home.appending(path: ".codex/config.toml")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            try Self.removingTOMLTable("mcp_servers.\(Self.serverName)", from: text).write(to: url, atomically: true, encoding: .utf8)
        case .claudeCode:
            guard let claude = claudeCLI else { return }
            _ = try await ProcessRunner.run(claude, ["mcp", "remove", "--scope", "user", Self.serverName], timeout: .seconds(15))
        }
    }

    public enum RegistrationError: Error, LocalizedError {
        case notInstalled(String)
        case unreadableConfig(String)
        case toolFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled(let app): "\(app) doesn't appear to be installed."
            case .unreadableConfig(let path): "\(path) isn't valid JSON, so Harbor left it untouched."
            case .toolFailed(let output): output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    // MARK: Helpers

    private var claudeCLI: String? {
        ExecutableLocator.find("claude", extraPaths: [home.appending(path: ".claude/local").path, home.appending(path: ".local/bin").path])
    }

    private func jsonConfigURL(_ app: MCPClientApp) -> URL {
        switch app {
        case .claudeDesktop: home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json")
        default: home.appending(path: ".cursor/mcp.json")
        }
    }

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func updateJSONConfig(_ url: URL, _ mutate: (inout [String: Any]) -> Void) throws {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let existing = readJSON(url) else { throw RegistrationError.unreadableConfig(url.path) }
            root = existing
            try backupOnce(url)
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        mutate(&servers)
        root["mcpServers"] = servers
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private func registerCodex() throws {
        let url = home.appending(path: ".codex/config.toml")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !existing.isEmpty { try backupOnce(url) }
        var text = Self.removingTOMLTable("mcp_servers.\(Self.serverName)", from: existing)
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        let escaped = bridgePath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        text += "\n[mcp_servers.\(Self.serverName)]\ncommand = \"\(escaped)\"\nargs = []\n"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Removes `[table]` and its keys (up to the next table header) from TOML text.
    static func removingTOMLTable(_ table: String, from text: String) -> String {
        var output: [Substring] = []
        var skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                skipping = trimmed == "[\(table)]"
            }
            if !skipping { output.append(line) }
        }
        return output.joined(separator: "\n")
    }

    private func backupOnce(_ url: URL) throws {
        let backup = url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".harbor-backup")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try FileManager.default.copyItem(at: url, to: backup)
    }
}
