import Foundation

/// The unified settings document (`settings.json`). Every group has complete defaults,
/// and decoding merges stored values over them, so old or hand-edited files never fail
/// to load and new options appear automatically.
public struct AppSettings: Codable, Hashable, Sendable {
    public var appearance = AppearanceSettings()
    public var terminal = TerminalSettings()
    public var shell = ShellSettings()
    public var ssh = SSHSettings()
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

    public init() {}
}

public struct AIControlSettings: Codable, Hashable, Sendable {
    public var mcpEnabled = true
    public var allowScreenReading = true
    public var inputPolicy: AIInputPolicy = .askEveryTime
    public var allowOpeningTabs = true
    public var allowClosingTabs = false
    /// Show a badge and tinted border while an assistant is acting on a tab.
    public var showActivityIndicator = true

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
