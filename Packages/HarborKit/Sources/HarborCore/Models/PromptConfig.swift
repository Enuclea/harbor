import Foundation

/// A shell prompt described independently of any shell. `PromptBuilder` (HarborShell)
/// renders it for zsh, bash and fish so one design applies everywhere.
public struct PromptConfig: Codable, Hashable, Sendable {
    public var segments: [PromptSegment]
    public var layout: PromptLayout
    /// The input marker, e.g. `❯`, `$`, `%`, `λ`.
    public var symbol: String
    public var symbolColor: PromptColor
    /// Symbol colour after a failing command, so failures are visible at a glance.
    public var errorColor: PromptColor
    /// Text placed between segments.
    public var separator: String
    /// Name of the preset this config started from, shown in the UI.
    public var presetName: String?

    public init(
        segments: [PromptSegment],
        layout: PromptLayout = .singleLine,
        symbol: String = "❯",
        symbolColor: PromptColor = .magenta,
        errorColor: PromptColor = .red,
        separator: String = " ",
        presetName: String? = nil
    ) {
        self.segments = segments
        self.layout = layout
        self.symbol = symbol
        self.symbolColor = symbolColor
        self.errorColor = errorColor
        self.separator = separator
        self.presetName = presetName
    }
}

public enum PromptLayout: String, Codable, Sendable, CaseIterable {
    /// Segments and symbol on one line.
    case singleLine
    /// Segments on the first line, symbol alone on the second — long paths never squeeze input.
    case twoLine
}

public struct PromptSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: PromptSegmentKind
    public var color: PromptColor
    public var bold: Bool

    public init(_ kind: PromptSegmentKind, color: PromptColor, bold: Bool = false, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.color = color
        self.bold = bold
    }
}

public enum PromptSegmentKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case user, host, userAtHost
    /// Path with `~` for home, e.g. `~/src/harbor`.
    case directory
    /// Last path component only, e.g. `harbor`.
    case directoryName
    case gitBranch
    case time
    /// Exit status of the last command, shown only when non-zero.
    case exitStatus
    /// Count of background jobs, shown only when non-zero.
    case jobs
    /// Active Python virtualenv name, shown only when set.
    case pythonEnvironment

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .user: "User"
        case .host: "Host"
        case .userAtHost: "user@host"
        case .directory: "Directory"
        case .directoryName: "Folder name"
        case .gitBranch: "Git branch"
        case .time: "Time"
        case .exitStatus: "Exit status"
        case .jobs: "Background jobs"
        case .pythonEnvironment: "Python env"
        }
    }

    /// Representative text for previews.
    public var sample: String {
        switch self {
        case .user: "dan"
        case .host: "mac"
        case .userAtHost: "dan@mac"
        case .directory: "~/src/harbor"
        case .directoryName: "harbor"
        case .gitBranch: "main"
        case .time: "14:05:09"
        case .exitStatus: "1"
        case .jobs: "✦1"
        case .pythonEnvironment: "(venv)"
        }
    }
}

/// The 16 ANSI colours plus the terminal default, so prompts follow the active theme.
public enum PromptColor: String, Codable, Sendable, CaseIterable, Identifiable {
    case `default`
    case black, red, green, yellow, blue, magenta, cyan, white
    case brightBlack, brightRed, brightGreen, brightYellow, brightBlue, brightMagenta, brightCyan, brightWhite

    public var id: String { rawValue }

    /// ANSI palette index, or nil for the terminal's default foreground.
    public var ansiIndex: Int? {
        switch self {
        case .default: nil
        case .black: 0
        case .red: 1
        case .green: 2
        case .yellow: 3
        case .blue: 4
        case .magenta: 5
        case .cyan: 6
        case .white: 7
        case .brightBlack: 8
        case .brightRed: 9
        case .brightGreen: 10
        case .brightYellow: 11
        case .brightBlue: 12
        case .brightMagenta: 13
        case .brightCyan: 14
        case .brightWhite: 15
        }
    }

    public var label: String {
        rawValue.replacingOccurrences(of: "bright", with: "bright ").capitalized
    }
}

/// Where the configured prompt is applied.
public enum PromptScope: String, Codable, Sendable, CaseIterable {
    /// Leave the user's own prompt alone.
    case keepExisting
    /// Inject only into shells Harbor launches; dotfiles are not touched.
    case harborSessions
    /// Also add a managed block to `~/.zshrc` / `~/.bashrc` so other terminals match.
    case everywhere

    public var label: String {
        switch self {
        case .keepExisting: "Keep my prompt"
        case .harborSessions: "Harbor sessions only"
        case .everywhere: "Everywhere (edits ~/.zshrc)"
        }
    }
}
