import Foundation

/// The direction or mode of an SSH port forward / proxy.
public enum PortForwardKind: String, Codable, Sendable, CaseIterable {
    /// `-L`: listen on this Mac and forward connections through the SSH server to a target host:port.
    case local
    /// `-R`: listen on the SSH server and forward connections back to a target host:port on/via this Mac.
    case remote
    /// `-D`: listen on this Mac as a SOCKS5 dynamic proxy routing traffic through the SSH server.
    case dynamic

    public var label: String {
        switch self {
        case .local: "Local (-L)"
        case .remote: "Remote (-R)"
        case .dynamic: "SOCKS5 (-D)"
        }
    }

    public var shortBadge: String {
        switch self {
        case .local: "-L"
        case .remote: "-R"
        case .dynamic: "SOCKS5"
        }
    }

    public var sshFlag: String {
        switch self {
        case .local: "-L"
        case .remote: "-R"
        case .dynamic: "-D"
        }
    }
}

public enum PortForwardParseError: Error, LocalizedError, Equatable {
    case emptyInput
    case invalidPort
    case invalidAddress
    case unrecognizedFormat

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            "Enter a port (e.g. 8080), target IP:port (10.0.0.1:8291), redirect (8080:3000), or SOCKS proxy (socks 1080)."
        case .invalidPort:
            "Ports must be between 1 and 65535."
        case .invalidAddress:
            "The bind or target address contains invalid characters."
        case .unrecognizedFormat:
            "Use port (8080), host:port (10.0.0.1:8291), local:remote (8080:3000), local:host:remote (8291:10.0.0.1:8291), -R 9000:3000, or socks 1080."
        }
    }
}

/// A saved or on-the-fly SSH port forward (`-L`, `-R`) or dynamic SOCKS5 proxy (`-D`).
public struct PortForwardRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: PortForwardKind
    public var bindAddress: String
    public var listenPort: Int
    public var targetHost: String
    public var targetPort: Int
    public var label: String?
    public var autoStart: Bool

    public init(
        id: UUID = UUID(),
        kind: PortForwardKind = .local,
        bindAddress: String = "127.0.0.1",
        listenPort: Int,
        targetHost: String = "127.0.0.1",
        targetPort: Int = 0,
        label: String? = nil,
        autoStart: Bool = true
    ) {
        self.id = id
        self.kind = kind
        let normalizedBind = Self.stripBrackets(bindAddress.trimmingCharacters(in: .whitespaces))
        self.bindAddress = normalizedBind.isEmpty ? "127.0.0.1" : normalizedBind
        self.listenPort = listenPort
        let normalizedTarget = Self.stripBrackets(targetHost.trimmingCharacters(in: .whitespaces))
        self.targetHost = normalizedTarget.isEmpty ? "127.0.0.1" : normalizedTarget
        self.targetPort = kind == .dynamic ? 0 : (targetPort == 0 ? listenPort : targetPort)
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = (trimmedLabel?.isEmpty == false) ? trimmedLabel : nil
        self.autoStart = autoStart
    }

    /// Unique key for the bound listener (`kind:bindAddress:listenPort`), used to detect duplicates.
    public var endpointKey: String {
        "\(kind.rawValue):\(bindAddress):\(listenPort)"
    }

    /// The OpenSSH specification passed after `-L`, `-R`, or `-D`.
    public var sshSpec: String {
        let bind = Self.sshFormattedAddress(bindAddress)
        switch kind {
        case .local, .remote:
            let target = Self.sshFormattedAddress(targetHost)
            return "\(bind):\(listenPort):\(target):\(targetPort)"
        case .dynamic:
            return "\(bind):\(listenPort)"
        }
    }

    /// OpenSSH command-line arguments for this rule, e.g. `["-L", "127.0.0.1:8080:127.0.0.1:3000"]`.
    public var sshArguments: [String] {
        [kind.sshFlag, sshSpec]
    }

    /// Concise human-readable description of the redirect/proxy.
    public var displaySummary: String {
        let localHostLabel = (bindAddress == "127.0.0.1" || bindAddress == "localhost" || bindAddress == "::1")
            ? "localhost"
            : Self.sshFormattedAddress(bindAddress)
        switch kind {
        case .local:
            let isLoopbackTarget = (targetHost == "127.0.0.1" || targetHost == "localhost" || targetHost == "::1")
            let remoteLabel = isLoopbackTarget ? "" : "\(Self.sshFormattedAddress(targetHost)):"
            return "\(localHostLabel):\(listenPort) → \(remoteLabel)\(targetPort)"
        case .remote:
            let isLoopbackTarget = (targetHost == "127.0.0.1" || targetHost == "localhost" || targetHost == "::1")
            let destLabel = isLoopbackTarget ? "localhost" : Self.sshFormattedAddress(targetHost)
            return "remote:\(listenPort) → \(destLabel):\(targetPort)"
        case .dynamic:
            return "SOCKS5 \(localHostLabel):\(listenPort)"
        }
    }

    /// Browser URL when this rule exposes a local TCP port (`-L`).
    public var localBrowserURL: URL? {
        guard kind == .local else { return nil }
        let rawHost = (bindAddress == "0.0.0.0" || bindAddress == "*" || bindAddress == "::") ? "127.0.0.1" : bindAddress
        let host = Self.sshFormattedAddress(rawHost)
        return URL(string: "http://\(host):\(listenPort)")
    }

    /// Ready-to-copy snippet (URL for local forwards, `ALL_PROXY=...` for SOCKS5, remote port for `-R`).
    public var copyableSnippet: String {
        let rawHost = (bindAddress == "0.0.0.0" || bindAddress == "*" || bindAddress == "::") ? "127.0.0.1" : bindAddress
        let host = Self.sshFormattedAddress(rawHost)
        switch kind {
        case .local:
            return "http://\(host):\(listenPort)"
        case .remote:
            return "\(Self.sshFormattedAddress(bindAddress)):\(listenPort)"
        case .dynamic:
            return "ALL_PROXY=socks5h://\(host):\(listenPort)"
        }
    }

    /// Builds a rule from structured UI fields (`This Mac` ⇄ `Remote` + optional `Target host`),
    /// supporting ports (`8291`), `IP:port` / `host:port` combos (`10.0.0.1:8291`, `[2001:db8::1]:8291`),
    /// bare hostnames/IPs paired with a port, or full shorthand specs pasted into either field.
    public static func build(
        kind: PortForwardKind,
        localInput: String,
        remoteInput: String,
        targetHostInput: String = "",
        label: String? = nil
    ) throws -> PortForwardRule {
        let local = localInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = remoteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = targetHostInput.trimmingCharacters(in: .whitespacesAndNewlines)

        if kind == .dynamic {
            return try parse(local.isEmpty ? remote : local, defaultKind: .dynamic, label: label)
        }

        if local.isEmpty && remote.isEmpty && target.isEmpty {
            throw PortForwardParseError.emptyInput
        }

        // Single-field shorthand (e.g. "8080", "8080:3000", "10.0.0.1:8291", "8291:10.0.0.1:8291", "-R 9000:3000").
        if remote.isEmpty && target.isEmpty {
            return try parse(local, defaultKind: kind, label: label)
        }
        if local.isEmpty && target.isEmpty {
            return try parse(remote, defaultKind: kind, label: label)
        }

        let targetEp = try parseEndpoint(target, allowPortOnly: false, allowHostOnly: true)

        // Support "8080:3000" in the first field alongside an explicit target host (e.g. "10.0.0.1").
        if remote.isEmpty, !local.isEmpty {
            let localCleaned = stripOptionalScheme(local)
            if !isValidIPv6(localCleaned),
               let pair = try? splitColonTokens(localCleaned),
               pair.count == 2,
               isNumericToken(pair[0]),
               isNumericToken(pair[1]) {
                let firstPort = try parsePort(pair[0])
                let secondPort = try parsePort(pair[1])
                let resolvedTargetHost = targetEp.host ?? "127.0.0.1"
                if kind == .local {
                    return PortForwardRule(
                        kind: .local,
                        bindAddress: "127.0.0.1",
                        listenPort: firstPort,
                        targetHost: resolvedTargetHost,
                        targetPort: targetEp.port ?? secondPort,
                        label: label
                    )
                } else {
                    return PortForwardRule(
                        kind: .remote,
                        bindAddress: "127.0.0.1",
                        listenPort: secondPort,
                        targetHost: resolvedTargetHost,
                        targetPort: firstPort,
                        label: label
                    )
                }
            }
        }

        let localEp = try parseEndpoint(local, allowPortOnly: true, allowHostOnly: kind == .remote)
        let remoteEp = try parseEndpoint(remote, allowPortOnly: true, allowHostOnly: true)

        switch kind {
        case .local:
            let bindAddress = localEp.host ?? "127.0.0.1"
            let targetHost = targetEp.host ?? remoteEp.host ?? "127.0.0.1"
            let remotePort = remoteEp.port ?? targetEp.port ?? localEp.port
            let listenPort = localEp.port ?? remotePort
            guard let listenPort, let remotePort else {
                throw PortForwardParseError.invalidPort
            }
            return PortForwardRule(
                kind: .local,
                bindAddress: bindAddress,
                listenPort: listenPort,
                targetHost: targetHost,
                targetPort: remotePort,
                label: label
            )

        case .remote:
            let bindAddress = remoteEp.host ?? "127.0.0.1"
            let targetHost = targetEp.host ?? localEp.host ?? "127.0.0.1"
            let macPort = localEp.port ?? targetEp.port ?? remoteEp.port
            let serverPort = remoteEp.port ?? macPort
            guard let serverPort, let macPort else {
                throw PortForwardParseError.invalidPort
            }
            return PortForwardRule(
                kind: .remote,
                bindAddress: bindAddress,
                listenPort: serverPort,
                targetHost: targetHost,
                targetPort: macPort,
                label: label
            )

        case .dynamic:
            let bindAddress = localEp.host ?? remoteEp.host ?? "127.0.0.1"
            guard let listenPort = localEp.port ?? remoteEp.port else {
                throw PortForwardParseError.invalidPort
            }
            return PortForwardRule(kind: .dynamic, bindAddress: bindAddress, listenPort: listenPort, label: label)
        }
    }

    /// Parses a quick redirect/proxy string such as:
    /// - `"8080"` -> Local `127.0.0.1:8080 -> 127.0.0.1:8080`
    /// - `"10.0.0.1:8291"` -> Local `127.0.0.1:8291 -> 10.0.0.1:8291`
    /// - `"8080:3000"` or `"8080->3000"` -> Local `127.0.0.1:8080 -> 127.0.0.1:3000`
    /// - `"5432:db.internal:5432"` -> Local `127.0.0.1:5432 -> db.internal:5432`
    /// - `"0.0.0.0:8080:127.0.0.1:3000"` -> Local `0.0.0.0:8080 -> 127.0.0.1:3000`
    /// - `"-R 9000:3000"` or `"remote 9000"` -> Remote `127.0.0.1:9000 -> 127.0.0.1:3000`
    /// - `"-D 1080"` or `"socks 1080"` or `"proxy 1080"` -> Dynamic SOCKS5 `127.0.0.1:1080`
    public static func parse(
        _ raw: String,
        defaultKind: PortForwardKind = .local,
        label: String? = nil
    ) throws -> PortForwardRule {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PortForwardParseError.emptyInput }

        var kind = defaultKind

        // Normalize arrow notation (`8080 -> 3000` or `8080->3000`) into colon notation.
        text = text.replacingOccurrences(of: "->", with: ":")
            .replacingOccurrences(of: "→", with: ":")

        // Check for leading kind token (e.g. "-L", "L", "local", "-R", "remote", "-D", "socks", "socks5", "proxy").
        let whitespaceParts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if whitespaceParts.count >= 2 {
            let prefix = whitespaceParts[0].lowercased()
            let remainder = whitespaceParts.dropFirst().joined()
            switch prefix {
            case "-l", "l", "local":
                kind = .local
                text = remainder
            case "-r", "r", "remote", "reverse":
                kind = .remote
                text = remainder
            case "-d", "d", "dynamic", "socks", "socks5", "proxy":
                kind = .dynamic
                text = remainder
            default:
                text = whitespaceParts.joined()
            }
        }

        if text.lowercased().hasPrefix("socks5://") || text.lowercased().hasPrefix("socks://") {
            kind = .dynamic
            if let range = text.range(of: "://") {
                text = String(text[range.upperBound...])
            }
        } else {
            text = stripOptionalScheme(text)
        }

        let parts = try splitColonTokens(text)
        guard !parts.isEmpty, !parts.contains(where: \.isEmpty) else {
            throw PortForwardParseError.unrecognizedFormat
        }

        switch kind {
        case .dynamic:
            switch parts.count {
            case 1:
                let port = try parsePort(parts[0])
                return PortForwardRule(kind: .dynamic, bindAddress: "127.0.0.1", listenPort: port, label: label)
            case 2:
                let bind = try validateAddress(parts[0])
                let port = try parsePort(parts[1])
                return PortForwardRule(kind: .dynamic, bindAddress: bind, listenPort: port, label: label)
            default:
                throw PortForwardParseError.unrecognizedFormat
            }

        case .local, .remote:
            switch parts.count {
            case 1:
                let port = try parsePort(parts[0])
                return PortForwardRule(
                    kind: kind,
                    bindAddress: "127.0.0.1",
                    listenPort: port,
                    targetHost: "127.0.0.1",
                    targetPort: port,
                    label: label
                )
            case 2:
                if isNumericToken(parts[0]) {
                    let listenPort = try parsePort(parts[0])
                    let targetPort = try parsePort(parts[1])
                    return PortForwardRule(
                        kind: kind,
                        bindAddress: "127.0.0.1",
                        listenPort: listenPort,
                        targetHost: "127.0.0.1",
                        targetPort: targetPort,
                        label: label
                    )
                } else {
                    let address = try validateAddress(parts[0])
                    let port = try parsePort(parts[1])
                    if address == "0.0.0.0" || address == "*" || address == "::" {
                        return PortForwardRule(
                            kind: kind,
                            bindAddress: address,
                            listenPort: port,
                            targetHost: "127.0.0.1",
                            targetPort: port,
                            label: label
                        )
                    }
                    return PortForwardRule(
                        kind: kind,
                        bindAddress: "127.0.0.1",
                        listenPort: port,
                        targetHost: address,
                        targetPort: port,
                        label: label
                    )
                }
            case 3:
                let listenPort = try parsePort(parts[0])
                let targetHost = try validateAddress(parts[1])
                let targetPort = try parsePort(parts[2])
                return PortForwardRule(
                    kind: kind,
                    bindAddress: "127.0.0.1",
                    listenPort: listenPort,
                    targetHost: targetHost,
                    targetPort: targetPort,
                    label: label
                )
            case 4:
                let bindAddress = try validateAddress(parts[0])
                let listenPort = try parsePort(parts[1])
                let targetHost = try validateAddress(parts[2])
                let targetPort = try parsePort(parts[3])
                return PortForwardRule(
                    kind: kind,
                    bindAddress: bindAddress,
                    listenPort: listenPort,
                    targetHost: targetHost,
                    targetPort: targetPort,
                    label: label
                )
            default:
                throw PortForwardParseError.unrecognizedFormat
            }
        }
    }

    public static func isValidPort(_ port: Int) -> Bool {
        (1...65_535).contains(port)
    }

    public static func isValidAddress(_ address: String) -> Bool {
        let stripped = stripBrackets(address)
        guard !stripped.isEmpty, !stripped.hasPrefix("-"), stripped.count <= 253 else { return false }
        if stripped.contains(":") {
            return isValidIPv6(stripped)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_*"))
        return stripped.unicodeScalars.allSatisfy(allowed.contains)
    }

    // MARK: Private parsing helpers

    private static func isValidIPv6(_ raw: String) -> Bool {
        let candidate = stripBrackets(raw)
        let colonCount = candidate.filter { $0 == ":" }.count
        guard colonCount >= 2, !candidate.hasPrefix("-"), candidate.count <= 253 else { return false }
        let hexAndDelimiters = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.%")
        let zoneSplit = candidate.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        guard let addressPart = zoneSplit.first, !addressPart.isEmpty,
              addressPart.unicodeScalars.allSatisfy(hexAndDelimiters.contains) else {
            return false
        }
        if zoneSplit.count == 2 {
            let zone = zoneSplit[1]
            let zoneAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            guard !zone.isEmpty, zone.unicodeScalars.allSatisfy(zoneAllowed.contains) else { return false }
        }
        return true
    }

    private static func stripBrackets(_ value: String) -> String {
        if value.hasPrefix("["), value.hasSuffix("]"), value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func sshFormattedAddress(_ address: String) -> String {
        address.contains(":") ? "[\(address)]" : address
    }

    private static func stripOptionalScheme(_ text: String) -> String {
        var result = text
        let lower = result.lowercased()
        for prefix in ["http://", "https://", "tcp://"] where lower.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
            break
        }
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func isNumericToken(_ token: String) -> Bool {
        let cleaned = token.replacingOccurrences(of: ",", with: "")
        return !cleaned.isEmpty && Int(cleaned) != nil
    }

    /// Splits a colon-delimited spec while keeping bracketed IPv6 literals (`[2001:db8::1]`) intact.
    private static func splitColonTokens(_ text: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var inBrackets = false
        for char in text {
            if char == "[" {
                guard !inBrackets, current.isEmpty else { throw PortForwardParseError.invalidAddress }
                inBrackets = true
                current.append(char)
            } else if char == "]" {
                guard inBrackets else { throw PortForwardParseError.invalidAddress }
                inBrackets = false
                current.append(char)
            } else if char == ":" && !inBrackets {
                tokens.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        guard !inBrackets else { throw PortForwardParseError.invalidAddress }
        tokens.append(current.trimmingCharacters(in: .whitespaces))
        return tokens
    }

    private static func parseEndpoint(
        _ raw: String,
        allowPortOnly: Bool,
        allowHostOnly: Bool
    ) throws -> (host: String?, port: Int?) {
        let trimmed = stripOptionalScheme(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return (nil, nil) }

        if allowHostOnly && isValidIPv6(trimmed) {
            return (stripBrackets(trimmed), nil)
        }

        let parts = try splitColonTokens(trimmed)
        guard !parts.contains(where: \.isEmpty) else {
            throw PortForwardParseError.unrecognizedFormat
        }

        switch parts.count {
        case 1:
            if isNumericToken(parts[0]) {
                guard allowPortOnly else { throw PortForwardParseError.invalidAddress }
                return (nil, try parsePort(parts[0]))
            } else {
                guard allowHostOnly else { throw PortForwardParseError.invalidPort }
                return (try validateAddress(parts[0]), nil)
            }
        case 2:
            let host = try validateAddress(parts[0])
            let port = try parsePort(parts[1])
            return (host, port)
        default:
            throw PortForwardParseError.unrecognizedFormat
        }
    }

    private static func parsePort(_ string: String) throws -> Int {
        let cleaned = string.replacingOccurrences(of: ",", with: "")
        guard let port = Int(cleaned), isValidPort(port) else {
            throw PortForwardParseError.invalidPort
        }
        return port
    }

    private static func validateAddress(_ string: String) throws -> String {
        guard isValidAddress(string) else {
            throw PortForwardParseError.invalidAddress
        }
        return stripBrackets(string)
    }
}
