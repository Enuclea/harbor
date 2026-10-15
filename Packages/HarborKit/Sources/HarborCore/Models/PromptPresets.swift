import Foundation

/// Starting points offered during onboarding and in the Prompt editor.
public enum PromptPreset: String, CaseIterable, Sendable, Identifiable {
    case harbor, classic, minimal, informative, developer

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .harbor: "Harbor"
        case .classic: "Classic"
        case .minimal: "Minimal"
        case .informative: "Informative"
        case .developer: "Developer"
        }
    }

    public var summary: String {
        switch self {
        case .harbor: "Folder, git branch and a coloured arrow that turns red on failure."
        case .classic: "Terminal.app's familiar user@host folder %."
        case .minimal: "Just the arrow. Maximum room for commands."
        case .informative: "Two lines: who, where, branch and time above a clean input line."
        case .developer: "Two lines with full path, branch, exit codes, jobs and Python env."
        }
    }

    public var config: PromptConfig {
        switch self {
        case .harbor:
            PromptConfig(
                segments: [
                    PromptSegment(.directory, color: .cyan, bold: true, id: .preset(1, 1)),
                    PromptSegment(.gitBranch, color: .brightBlack, id: .preset(1, 2)),
                ],
                symbol: "❯", symbolColor: .magenta, errorColor: .red, presetName: title)
        case .classic:
            PromptConfig(
                segments: [
                    PromptSegment(.userAtHost, color: .default, id: .preset(2, 1)),
                    PromptSegment(.directoryName, color: .default, id: .preset(2, 2)),
                ],
                symbol: "%", symbolColor: .default, errorColor: .default, presetName: title)
        case .minimal:
            PromptConfig(segments: [], symbol: "❯", symbolColor: .green, errorColor: .red, presetName: title)
        case .informative:
            PromptConfig(
                segments: [
                    PromptSegment(.userAtHost, color: .green, bold: true, id: .preset(4, 1)),
                    PromptSegment(.directory, color: .blue, bold: true, id: .preset(4, 2)),
                    PromptSegment(.gitBranch, color: .magenta, id: .preset(4, 3)),
                    PromptSegment(.time, color: .brightBlack, id: .preset(4, 4)),
                ],
                layout: .twoLine, symbol: "❯", symbolColor: .cyan, errorColor: .red, presetName: title)
        case .developer:
            PromptConfig(
                segments: [
                    PromptSegment(.pythonEnvironment, color: .yellow, id: .preset(5, 1)),
                    PromptSegment(.user, color: .green, id: .preset(5, 2)),
                    PromptSegment(.directory, color: .cyan, bold: true, id: .preset(5, 3)),
                    PromptSegment(.gitBranch, color: .magenta, id: .preset(5, 4)),
                    PromptSegment(.jobs, color: .yellow, id: .preset(5, 5)),
                    PromptSegment(.exitStatus, color: .red, bold: true, id: .preset(5, 6)),
                ],
                layout: .twoLine, symbol: "λ", symbolColor: .brightBlue, errorColor: .red, presetName: title)
        }
    }
}

extension UUID {
    /// Stable identifiers for preset segments, so default settings compare equal across launches.
    static func preset(_ preset: UInt8, _ segment: UInt8) -> UUID {
        UUID(uuid: (0x48, 0x41, 0x52, 0x42, 0x4F, 0x52, 0x40, preset, 0x80, segment, 0, 0, 0, 0, 0, 0))
    }
}
