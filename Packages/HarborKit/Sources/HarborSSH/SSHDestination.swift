import Foundation
import HarborCore

public enum SSHDestinationError: Error, LocalizedError, Equatable {
    case empty
    case invalidHost(String)
    case invalidPort(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "Enter a host, like user@example.com"
        case .invalidHost(let host): "“\(host)” isn't a valid host name"
        case .invalidPort(let port): "“\(port)” isn't a valid port"
        }
    }
}

/// Parses what people type into Quick Connect or pass over MCP:
/// `host`, `user@host`, `user@host:2222`, `ssh://user@host:2222`, `[2001:db8::1]:22`.
///
/// Host names are validated strictly. A destination beginning with `-` would otherwise
/// be read by ssh as an option (e.g. `-oProxyCommand=…`), which is command execution.
public enum SSHDestination {
    public static func parse(_ input: String) throws -> HostProfile {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SSHDestinationError.empty }
        if text.lowercased().hasPrefix("ssh://") { text = String(text.dropFirst(6)) }
        if text.hasSuffix("/") { text.removeLast() }

        var user: String?
        if let at = text.lastIndex(of: "@") {
            user = String(text[..<at])
            text = String(text[text.index(after: at)...])
        }

        var host = text
        var port: Int?
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":") { port = try parsePort(String(rest.dropFirst())) }
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            host = String(text[..<colon])
            port = try parsePort(String(text[text.index(after: colon)...]))
        }

        guard isValidHost(host) else { throw SSHDestinationError.invalidHost(host) }
        if let user, !isValidUser(user) { throw SSHDestinationError.invalidHost("\(user)@\(host)") }
        return HostProfile(name: host, hostname: host, user: user?.isEmpty == true ? nil : user, port: port)
    }

    public static func isValidHost(_ host: String) -> Bool {
        guard let first = host.first, first != "-", host.count <= 253 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:%"))
        return host.unicodeScalars.allSatisfy(allowed.contains)
    }

    public static func isValidUser(_ user: String) -> Bool {
        guard user.first != "-" else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-$\\"))
        return user.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func parsePort(_ text: String) throws -> Int {
        guard let port = Int(text), (1...65_535).contains(port) else { throw SSHDestinationError.invalidPort(text) }
        return port
    }
}
