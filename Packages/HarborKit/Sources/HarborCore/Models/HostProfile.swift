import Foundation

/// A saved SSH destination — the unit behind "one-click hosts".
public struct HostProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: HostID
    /// Display name, e.g. "Prod API".
    public var name: String
    /// DNS name, IP, or (when `usesSSHConfigAlias`) a `Host` alias from `~/.ssh/config`.
    public var hostname: String
    public var user: String?
    public var port: Int?
    /// Path to a private key; `~` is expanded at launch.
    public var identityFile: String?
    /// `ProxyJump` destination(s), comma-separated as ssh expects.
    public var jumpHost: String?
    /// When true, `hostname` is passed to ssh untouched so the user's config block applies.
    public var usesSSHConfigAlias: Bool
    public var forwardAgent: Bool
    /// Command run after login instead of the remote login shell (e.g. `tmux new -As main`).
    public var startupCommand: String?
    /// Directory the file flyout opens in; defaults to the remote home.
    public var remoteDirectory: String?
    public var tags: [String]
    public var color: HostColor
    /// Theme to use for this host's tabs (Terminal.app-style "profile per host", e.g. red for prod).
    public var themeID: String?
    public var isFavorite: Bool
    public var lastConnected: Date?
    public var notes: String?
    /// Harbor's shell integration is installed on the host (status, exit codes and the
    /// running command then show for this host's tabs).
    public var remoteIntegration: Bool
    /// The host's sshd drops `LC_TERMINAL`, so Harbor starts the login shell with the
    /// marker set explicitly instead.
    public var remoteIntegrationMarker: Bool
    /// Show `name` instead of the server's hostname: on the tab, and (with shell
    /// integration on the host) wherever the prompt shows the hostname.
    public var showsNameInPrompt: Bool

    public init(
        id: HostID = HostID(),
        name: String,
        hostname: String,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        jumpHost: String? = nil,
        usesSSHConfigAlias: Bool = false,
        forwardAgent: Bool = false,
        startupCommand: String? = nil,
        remoteDirectory: String? = nil,
        tags: [String] = [],
        color: HostColor = .none,
        themeID: String? = nil,
        isFavorite: Bool = false,
        lastConnected: Date? = nil,
        notes: String? = nil,
        remoteIntegration: Bool = false,
        remoteIntegrationMarker: Bool = false,
        showsNameInPrompt: Bool = false
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.jumpHost = jumpHost
        self.usesSSHConfigAlias = usesSSHConfigAlias
        self.forwardAgent = forwardAgent
        self.startupCommand = startupCommand
        self.remoteDirectory = remoteDirectory
        self.tags = tags
        self.color = color
        self.themeID = themeID
        self.isFavorite = isFavorite
        self.lastConnected = lastConnected
        self.notes = notes
        self.remoteIntegration = remoteIntegration
        self.remoteIntegrationMarker = remoteIntegrationMarker
        self.showsNameInPrompt = showsNameInPrompt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, hostname, user, port, identityFile, jumpHost, usesSSHConfigAlias, forwardAgent
        case startupCommand, remoteDirectory, tags, color, themeID, isFavorite, lastConnected, notes
        case remoteIntegration, remoteIntegrationMarker, showsNameInPrompt
    }

    /// Lenient decoding: only `hostname` is required, so files written by older or newer
    /// versions (or by hand) always load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let hostname = try c.decode(String.self, forKey: .hostname)
        self.init(
            id: try c.decodeIfPresent(HostID.self, forKey: .id) ?? HostID(),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? hostname,
            hostname: hostname,
            user: try c.decodeIfPresent(String.self, forKey: .user),
            port: try c.decodeIfPresent(Int.self, forKey: .port),
            identityFile: try c.decodeIfPresent(String.self, forKey: .identityFile),
            jumpHost: try c.decodeIfPresent(String.self, forKey: .jumpHost),
            usesSSHConfigAlias: try c.decodeIfPresent(Bool.self, forKey: .usesSSHConfigAlias) ?? false,
            forwardAgent: try c.decodeIfPresent(Bool.self, forKey: .forwardAgent) ?? false,
            startupCommand: try c.decodeIfPresent(String.self, forKey: .startupCommand),
            remoteDirectory: try c.decodeIfPresent(String.self, forKey: .remoteDirectory),
            tags: try c.decodeIfPresent([String].self, forKey: .tags) ?? [],
            color: (try? c.decodeIfPresent(HostColor.self, forKey: .color)) ?? HostColor.none,
            themeID: try c.decodeIfPresent(String.self, forKey: .themeID),
            isFavorite: try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false,
            lastConnected: try c.decodeIfPresent(Date.self, forKey: .lastConnected),
            notes: try c.decodeIfPresent(String.self, forKey: .notes),
            remoteIntegration: try c.decodeIfPresent(Bool.self, forKey: .remoteIntegration) ?? false,
            remoteIntegrationMarker: try c.decodeIfPresent(Bool.self, forKey: .remoteIntegrationMarker) ?? false,
            showsNameInPrompt: try c.decodeIfPresent(Bool.self, forKey: .showsNameInPrompt) ?? false
        )
    }

    /// `user@host:port` as a human would type it.
    public var destinationLabel: String {
        var label = hostname
        if let user, !user.isEmpty { label = "\(user)@\(label)" }
        if let port, port != 22 { label += ":\(port)" }
        return label
    }

    /// The name to show in the host's prompt, when `showsNameInPrompt` is on. Reduced to
    /// characters that every shell's prompt prints literally (letters, digits, space and
    /// `._+-`); anything else becomes `-`.
    public var promptName: String? {
        guard showsNameInPrompt else { return nil }
        let name = Self.promptSafe(name)
        return name.isEmpty ? nil : name
    }

    public static func promptSafe(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._+-"))
        let mapped = String(String.UnicodeScalarView(text.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }))
        return String(mapped.trimmingCharacters(in: .whitespaces).prefix(64))
    }

    /// Lowercased text used for fuzzy matching in Quick Connect and by AI tools.
    public var searchText: String {
        ([name, hostname, user ?? ""] + tags).joined(separator: " ").lowercased()
    }
}

/// Tab accent colours for hosts. Named rather than RGB so they adapt to light/dark.
public enum HostColor: String, Codable, Sendable, CaseIterable {
    case none, red, orange, yellow, green, teal, blue, purple, pink, gray
}
