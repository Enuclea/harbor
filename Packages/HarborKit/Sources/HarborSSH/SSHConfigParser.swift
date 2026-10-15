import Darwin
import Foundation
import HarborCore

/// One concrete `Host` alias from `~/.ssh/config` (wildcard patterns are skipped).
public struct SSHConfigEntry: Equatable, Sendable {
    public var alias: String
    public var hostname: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var proxyJump: String?

    public init(alias: String, hostname: String? = nil, user: String? = nil, port: Int? = nil,
                identityFile: String? = nil, proxyJump: String? = nil) {
        self.alias = alias
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
    }

    /// `user@hostname:port` as configured, for display.
    public var resolvedDestination: String {
        var label = hostname ?? alias
        if let user { label = "\(user)@\(label)" }
        if let port, port != 22 { label += ":\(port)" }
        return label
    }

    /// A Harbor host that defers to the config entry, so the user's options keep applying.
    public func makeHostProfile() -> HostProfile {
        HostProfile(
            name: alias,
            hostname: alias,
            usesSSHConfigAlias: true,
            tags: ["ssh config"],
            notes: "Imported from ~/.ssh/config (\(resolvedDestination))")
    }
}

/// Parses the subset of `ssh_config(5)` needed to offer one-click hosts:
/// `Host` blocks, common keywords, `Include` (with globs) and `Match` (skipped).
public enum SSHConfigParser {
    public static func load(from url: URL, sshDirectory: URL) -> [SSHConfigEntry] {
        var visited = Set<String>()
        return load(url, sshDirectory: sshDirectory, visited: &visited)
    }

    private static func load(_ url: URL, sshDirectory: URL, visited: inout Set<String>) -> [SSHConfigEntry] {
        guard visited.insert(url.standardizedFileURL.path).inserted,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var nested: [SSHConfigEntry] = []
        let entries = parse(text) { pattern in
            for path in expandInclude(pattern, sshDirectory: sshDirectory) {
                nested += load(URL(fileURLWithPath: path), sshDirectory: sshDirectory, visited: &visited)
            }
        }
        return merge(entries + nested)
    }

    /// Parses config text. `onInclude` receives each `Include` argument.
    public static func parse(_ text: String, onInclude: (String) -> Void = { _ in }) -> [SSHConfigEntry] {
        var entries: [SSHConfigEntry] = []
        var current: [Int] = [] // indices into `entries` for the active Host block
        var inMatchBlock = false

        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let (keyword, values) = tokenize(String(rawLine)) else { continue }
            switch keyword {
            case "host":
                inMatchBlock = false
                current = []
                for pattern in values where !isPattern(pattern) {
                    entries.append(SSHConfigEntry(alias: pattern))
                    current.append(entries.count - 1)
                }
            case "match":
                inMatchBlock = true
                current = []
            case "include":
                values.forEach(onInclude)
            default:
                guard !inMatchBlock, let value = values.first else { continue }
                for index in current { apply(keyword, value, to: &entries[index]) }
            }
        }
        return entries
    }

    // MARK: Helpers

    private static func apply(_ keyword: String, _ value: String, to entry: inout SSHConfigEntry) {
        // ssh uses the first value it sees for each keyword.
        switch keyword {
        case "hostname": entry.hostname = entry.hostname ?? value
        case "user": entry.user = entry.user ?? value
        case "port": entry.port = entry.port ?? Int(value)
        case "identityfile": entry.identityFile = entry.identityFile ?? value
        case "proxyjump": entry.proxyJump = entry.proxyJump ?? value
        default: break
        }
    }

    /// Splits `Keyword value…` or `Keyword=value`, honouring quotes and comments.
    static func tokenize(_ line: String) -> (String, [String])? {
        var tokens: [String] = []
        var token = ""
        var inQuotes = false
        var sawEquals = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == "#", !inQuotes, token.isEmpty {
                break
            } else if !inQuotes, character.isWhitespace || (character == "=" && tokens.isEmpty && !sawEquals) {
                if character == "=" { sawEquals = true }
                if !token.isEmpty { tokens.append(token); token = "" }
            } else {
                token.append(character)
            }
        }
        if !token.isEmpty { tokens.append(token) }
        guard let keyword = tokens.first else { return nil }
        return (keyword.lowercased(), Array(tokens.dropFirst()))
    }

    private static func isPattern(_ host: String) -> Bool {
        host.contains { "*?!".contains($0) }
    }

    /// Later duplicates of an alias add missing fields rather than creating a second host.
    private static func merge(_ entries: [SSHConfigEntry]) -> [SSHConfigEntry] {
        var order: [String] = []
        var byAlias: [String: SSHConfigEntry] = [:]
        for entry in entries {
            if var existing = byAlias[entry.alias] {
                existing.hostname = existing.hostname ?? entry.hostname
                existing.user = existing.user ?? entry.user
                existing.port = existing.port ?? entry.port
                existing.identityFile = existing.identityFile ?? entry.identityFile
                existing.proxyJump = existing.proxyJump ?? entry.proxyJump
                byAlias[entry.alias] = existing
            } else {
                order.append(entry.alias)
                byAlias[entry.alias] = entry
            }
        }
        return order.compactMap { byAlias[$0] }
    }

    private static func expandInclude(_ pattern: String, sshDirectory: URL) -> [String] {
        var path = (pattern as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = sshDirectory.appending(path: path).path }
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(path, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in
            result.gl_pathv[index].map { String(cString: $0) }
        }
    }
}
