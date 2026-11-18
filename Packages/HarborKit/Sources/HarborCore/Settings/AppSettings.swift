import Foundation

/// The unified settings document (`settings.json`). Every group has complete defaults,
/// and decoding merges stored values over them, so old or hand-edited files never fail
/// to load and new options appear automatically.
public struct AppSettings: Codable, Hashable, Sendable {
    public var appearance = AppearanceSettings()
    public var terminal = TerminalSettings()
    public var shell = ShellSettings()
    public var ssh = SSHSettings()
    public var github = GitHubRepoSettings()
    public var ai = AIControlSettings()
    public var remote = RemoteAccessSettings()
    public var logging = LoggingSettings()
    public var onboarding = OnboardingState()

    public init() {}
}

public struct AppearanceSettings: Codable, Hashable, Sendable {
    public var themeID = BuiltInThemes.defaultDarkID
    /// When set, the theme follows the system appearance using `lightThemeID` in light mode.
    public var followSystemAppearance = false
    public var lightThemeID = BuiltInThemes.defaultLightID
    /// PostScript or family name; nil means the system monospaced font (SF Mono).
    public var fontName: String?
    public var fontSize: Double = 13
    public var cursorShape: CursorShape = .block
    public var cursorBlinks = true
    /// 0…1. Below 1 the default background becomes translucent like Terminal.app.
    public var backgroundOpacity: Double = 0.94
    /// Blur whatever is behind a translucent window.
    public var backgroundBlur = true
    public var useMetalRenderer = true
    public var brightBoldText = true
    /// Points of padding between the window edge and the text grid.
    public var contentPadding: Double = 8
    public var initialColumns = 100
    public var initialRows = 30
    public static let columnRange = 40...400
    public static let rowRange = 10...200

    public init() {}
}

public enum CursorShape: String, Codable, Sendable, CaseIterable {
    case block, underline, bar
}

public struct TerminalSettings: Codable, Hashable, Sendable {
    public var scrollbackLines = 10_000
    public var optionAsMeta = true
    public var bell: BellMode = .visual
    /// Bounce the Dock icon and badge the tab when a background tab rings the bell.
    public var notifyOnBackgroundBell = true
    /// Post a desktop notification when a command running longer than `longCommandThresholdSeconds`
    /// finishes in an unfocused tab or background window.
    public var notifyOnLongCommandCompletion = true
    public var longCommandThresholdSeconds = 15
    public var exitBehavior: ExitBehavior = .closeIfClean
    public var confirmCloseWithRunningProcess = true
    public var newTabDirectory: NewTabDirectory = .sameAsCurrent
    public var copyOnSelect = false
    /// OSC 52: programs may place text on the clipboard.
    public var allowClipboardWrite = true
    /// OSC 52 query: programs may read the clipboard. Off by default; it can leak secrets.
    public var allowClipboardRead = false
    public var restoreSessionsOnLaunch = true
    public var termType = "xterm-256color"

    public init() {}
}

public enum BellMode: String, Codable, Sendable, CaseIterable {
    case none, sound, visual, soundAndVisual
}

public enum ExitBehavior: String, Codable, Sendable, CaseIterable {
    case close, closeIfClean, keepOpen

    public var label: String {
        switch self {
        case .close: "Close the tab"
        case .closeIfClean: "Close if the shell exited cleanly"
        case .keepOpen: "Don't close the tab"
        }
    }
}

public enum NewTabDirectory: String, Codable, Sendable, CaseIterable {
    case home, sameAsCurrent

    public var label: String {
        switch self {
        case .home: "Home folder"
        case .sameAsCurrent: "Same working directory"
        }
    }
}

public struct ShellSettings: Codable, Hashable, Sendable {
    /// nil means the user's login shell from the directory service.
    public var shellPath: String?
    public var launchAsLoginShell = true
    public var shellIntegration = true
    public var prompt = PromptPreset.harbor.config
    public var promptScope: PromptScope = .harborSessions
    public var extraEnvironment: [String: String] = [:]

    public init() {}
}

public struct SSHSettings: Codable, Hashable, Sendable {
    public var sshPath = "/usr/bin/ssh"
    /// Share one authenticated connection between the tab, the file flyout and extra tabs.
    public var connectionSharing = true
    /// Seconds a shared connection stays open after the last tab closes.
    public var connectionPersistSeconds = 600
    public var serverAliveInterval = 30
    public var forwardAgentByDefault = false
    /// Offer to store key passphrases in the macOS Keychain (`ssh-add --apple-use-keychain`).
    public var storePassphrasesInKeychain = true
    /// Automatically attempt to reconnect SSH sessions that drop unexpectedly (exit 255).
    public var autoReconnectDroppedSessions = false
    /// Recently connected ad-hoc destinations (`user@host:port`) from Quick Connect.
    public var recentDestinations: [HostProfile] = []

    public init() {}
}

public struct AIControlSettings: Codable, Hashable, Sendable {
    public var mcpEnabled = true
    public var allowScreenReading = true
    public var inputPolicy: AIInputPolicy = .askEveryTime
    /// Automatically allow safe, single-command read-only inspections without prompting.
    public var autoAllowReadOnlyCommands = false
    public var allowedCommandPrefixes: [String] = Self.defaultReadOnlyPrefixes
    public var allowOpeningTabs = true
    public var allowClosingTabs = false
    /// Show a badge and tinted border while an assistant is acting on a tab.
    public var showActivityIndicator = true
    /// Built-in token-aware AI assist (command drafting, log parsing, continuation, smart alerts).
    public var onboard = OnboardAISettings()

    public static let defaultReadOnlyPrefixes: [String] = [
        "ls", "pwd", "whoami", "uname", "date", "uptime", "df", "du",
        "git status", "git diff", "git log", "git branch", "git show",
        "cat", "head", "tail", "wc", "rg", "grep", "which", "env", "ps"
    ]

    public init() {}
}

public enum AIInputPolicy: String, Codable, Sendable, CaseIterable {
    case deny, askEveryTime, askOncePerTab, allow

    public var label: String {
        switch self {
        case .deny: "Never"
        case .askEveryTime: "Ask every time"
        case .askOncePerTab: "Ask once per tab"
        case .allow: "Always allow"
        }
    }
}

public enum AIProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case anthropic
    case openAICompatible
    case gemini
    case localOllama

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .anthropic: "Anthropic (Claude)"
        case .openAICompatible: "OpenAI / Compatible"
        case .gemini: "Google Gemini"
        case .localOllama: "Local (Ollama / LM Studio)"
        }
    }

    public var defaultModel: String {
        switch self {
        case .anthropic: "claude-3-5-haiku-latest"
        case .openAICompatible: "gpt-4o-mini"
        case .gemini: "gemini-2.5-flash"
        case .localOllama: "qwen2.5-coder:7b"
        }
    }

    public var defaultEndpoint: String {
        switch self {
        case .anthropic: "https://api.anthropic.com/v1/messages"
        case .openAICompatible: "https://api.openai.com/v1/chat/completions"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/models"
        case .localOllama: "http://127.0.0.1:11434/v1/chat/completions"
        }
    }

    public var requiresAPIKey: Bool {
        self != .localOllama
    }
}

/// Built-in, token-aware AI assist (force multiplier). Secrets live in Keychain only.
public struct OnboardAISettings: Codable, Hashable, Sendable {
    public var enabled = false
    public var provider: AIProviderKind = .anthropic
    /// Empty uses `provider.defaultModel`.
    public var model = ""
    /// Empty uses `provider.defaultEndpoint`.
    public var baseURL = ""
    /// Strict cap on input context tokens sent per request.
    public var maxContextTokens = 1_500
    /// Strict cap on completion tokens per response.
    public var maxOutputTokens = 400
    /// Show a non-intrusive "Explain exit <code>" chip when a command fails.
    public var offerOnCommandFailure = true
    /// Offer a 1-click "Suggest Next Step" continuation chip after commands finish.
    public var offerContinuation = false
    /// Summarize background command failures in desktop notifications.
    public var smartBackgroundAlerts = true

    public init() {}

    public var effectiveModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultModel : trimmed
    }

    public var effectiveEndpoint: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultEndpoint : trimmed
    }

    public var keychainAccount: String {
        "onboard-ai.\(provider.rawValue)"
    }
}

public struct RemoteAccessSettings: Codable, Hashable, Sendable {
    public var enabled = false
    public var port = 47_821
    public var tunnel: TunnelKind = .none
    /// When false, browsers can watch sessions but not type.
    public var allowInput = true
    public var allowOpeningSessions = true
    public var sessionLifetimeHours = 12
    /// The public hostname for a Cloudflare named tunnel (configured in the Cloudflare
    /// dashboard), e.g. `term.example.com`. Quick tunnels and Tailscale report their own.
    public var publicHostname: String?

    public init() {}
}

public enum TunnelKind: String, Codable, Sendable, CaseIterable {
    case none, cloudflareQuick, cloudflareNamed, tailscaleServe

    public var label: String {
        switch self {
        case .none: "Local only"
        case .cloudflareQuick: "Cloudflare quick tunnel"
        case .cloudflareNamed: "Cloudflare named tunnel"
        case .tailscaleServe: "Tailscale Serve"
        }
    }
}

public struct LoggingSettings: Codable, Hashable, Sendable {
    public var level: LogLevel = .info
    public var retentionDays = 14
    public var sessionRecording: SessionRecordingMode = .off

    public init() {}
}

public enum SessionRecordingMode: String, Codable, Sendable, CaseIterable {
    case off
    /// Plain text with escape sequences removed.
    case text
    /// asciicast v2 — replayable with `asciinema play`.
    case asciicast

    public var label: String {
        switch self {
        case .off: "Off"
        case .text: "Plain text"
        case .asciicast: "asciicast (replayable)"
        }
    }
}

public struct OnboardingState: Codable, Hashable, Sendable {
    /// Bumped when onboarding gains steps worth showing to existing users.
    public static let currentVersion = 1
    public var completedVersion = 0

    public var needsOnboarding: Bool { completedVersion < Self.currentVersion }

    public init() {}
}

public enum GitHubSSHKeySource: String, Codable, Sendable, CaseIterable, Identifiable {
    case keychainDeployKey
    case sshKeyFile

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .keychainDeployKey: "Dedicated Read-Only Deploy Key (Keychain)"
        case .sshKeyFile: "Existing SSH Key File (~/.ssh)"
        }
    }
}

/// Configuration for pulling pre-canned scripts/playbooks from a closed GitHub repository
/// using a read-only SSH deploy key. Private keys live exclusively in the macOS Keychain.
public struct GitHubRepoSettings: Codable, Hashable, Sendable {
    public static let keychainAccount = "github.readonly-deploy-key"

    /// GitHub repository URL (`git@github.com:owner/repo.git` or `https://github.com/owner/repo`).
    public var repositoryURL = ""
    /// Branch or tag to pull (empty uses the remote default branch).
    public var branch = "main"
    /// Optional subdirectory inside the repository where scripts live (e.g. `scripts`).
    public var scriptsSubdirectory = ""
    /// How the read-only SSH key is supplied.
    public var keySource: GitHubSSHKeySource = .keychainDeployKey
    /// Path to an SSH private key file when `keySource == .sshKeyFile`.
    public var sshKeyPath: String?
    /// Public half (`ssh-ed25519 AAAAC3...`) of the read-only deploy key for copying to GitHub.
    public var deployPublicKey = ""
    /// Automatically pull the latest scripts when Harbor launches.
    public var autoPullOnLaunch = false
    /// Pull latest changes before executing a script on the fly.
    public var pullBeforeRun = true
    /// Non-secret default variable values (`VAR_NAME: value`) used when parameterizing scripts.
    public var variableDefaults: [String: String] = [:]
    /// Last synced git commit short SHA.
    public var lastSyncedCommit: String?
    /// Last synced timestamp.
    public var lastSyncedAt: Date?

    public init() {}

    /// Converts browser HTTPS GitHub URLs (`https://github.com/owner/repo`) into SSH (`git@github.com:owner/repo.git`)
    /// so read-only SSH deploy keys work regardless of how the project URL was entered.
    public var normalizedSSHURL: String {
        let trimmed = repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("git@") || trimmed.hasPrefix("ssh://") || trimmed.hasPrefix("/") || trimmed.hasPrefix("file://") {
            return trimmed
        }
        var stripped = trimmed
        for prefix in ["https://", "http://"] where stripped.lowercased().hasPrefix(prefix) {
            stripped = String(stripped.dropFirst(prefix.count))
        }
        if let slashIndex = stripped.firstIndex(of: "/") {
            let host = String(stripped[..<slashIndex])
            var path = String(stripped[stripped.index(after: slashIndex)...])
            while path.hasSuffix("/") { path.removeLast() }
            if !path.isEmpty, !host.isEmpty, host.contains(".") {
                if !path.hasSuffix(".git") { path += ".git" }
                return "git@\(host):\(path)"
            }
        }
        return trimmed
    }

    /// Direct link to the repository's "Deploy keys" settings page on GitHub, if recognizable.
    public var webDeployKeysURL: URL? {
        guard let (host, ownerRepo) = parsedHostAndOwnerRepo else { return nil }
        return URL(string: "https://\(host)/\(ownerRepo)/settings/keys")
    }

    /// Direct link to the repository on the web, if recognizable.
    public var webRepoURL: URL? {
        guard let (host, ownerRepo) = parsedHostAndOwnerRepo else { return nil }
        return URL(string: "https://\(host)/\(ownerRepo)")
    }

    private var parsedHostAndOwnerRepo: (host: String, ownerRepo: String)? {
        let ssh = normalizedSSHURL
        if ssh.hasPrefix("git@"), let colon = ssh.firstIndex(of: ":") {
            let host = String(ssh[ssh.index( ssh.startIndex, offsetBy: 4)..<colon])
            var path = String(ssh[ssh.index(after: colon)...])
            if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
            let parts = path.split(separator: "/")
            if parts.count >= 2 {
                return (host, "\(parts[0])/\(parts[1])")
            }
        }
        return nil
    }
}

