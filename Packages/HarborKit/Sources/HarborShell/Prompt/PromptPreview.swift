import Foundation
import HarborCore

/// A styled span of preview text. The UI resolves `color` against the active theme so the
/// preview matches what the shell will draw.
public struct PromptPreviewRun: Hashable, Sendable {
    public let text: String
    public let color: PromptColor
    public let bold: Bool
}

/// Builds a shell-independent preview of a prompt design using sample values.
public enum PromptPreview {
    /// One array of runs per line.
    public static func lines(for config: PromptConfig, lastCommandFailed: Bool = false) -> [[PromptPreviewRun]] {
        var first: [PromptPreviewRun] = []
        for segment in config.segments {
            if segment.kind == .exitStatus, !lastCommandFailed { continue }
            first.append(PromptPreviewRun(text: segment.kind.sample, color: segment.color, bold: segment.bold))
            first.append(PromptPreviewRun(text: config.separator, color: .default, bold: false))
        }
        let symbol = PromptPreviewRun(
            text: config.symbol + " ",
            color: lastCommandFailed ? config.errorColor : config.symbolColor,
            bold: false)
        switch config.layout {
        case .singleLine: return [first + [symbol]]
        case .twoLine: return [first, [symbol]]
        }
    }
}
