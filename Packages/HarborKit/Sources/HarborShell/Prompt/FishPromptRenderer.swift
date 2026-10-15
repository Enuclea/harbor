import Foundation
import HarborCore

struct FishPromptRenderer: PromptRenderer {
    func render(_ config: PromptConfig) -> String {
        let kinds = Set(config.segments.map(\.kind))
        var lines = [PromptBuilder.header(for: config), ""]
        if kinds.contains(.pythonEnvironment) {
            lines.append("set -gx VIRTUAL_ENV_DISABLE_PROMPT 1")
        }
        lines.append("function fish_prompt")
        lines.append("    set -l __harbor_status $status")
        lines.append("    set -l fish_prompt_pwd_dir_length 0")
        for segment in config.segments {
            lines += block(for: segment, separator: config.separator).map { "    " + $0 }
        }
        if config.layout == .twoLine {
            lines.append("    printf '\\n'")
        }
        lines += symbol(config).map { "    " + $0 }
        lines.append("end")
        return lines.joined(separator: "\n") + "\n"
    }

    private func block(for segment: PromptSegment, separator: String) -> [String] {
        let sep = quoted(separator)
        switch segment.kind {
        case .user: return styled(segment, "$USER", sep)
        case .host: return styled(segment, "(prompt_hostname)", sep)
        case .userAtHost: return styled(segment, "\"$USER@\"(prompt_hostname)", sep)
        case .directory: return styled(segment, "(prompt_pwd)", sep)
        case .directoryName: return styled(segment, "(basename (prompt_pwd))", sep)
        case .time: return styled(segment, "(date +%H:%M:%S)", sep)
        case .gitBranch:
            return ["set -l __b (command git symbolic-ref --short HEAD 2>/dev/null; or command git rev-parse --short HEAD 2>/dev/null)",
                    "if test -n \"$__b\""] + styled(segment, "$__b", sep).map { "    " + $0 } + ["end"]
        case .exitStatus:
            return ["if test $__harbor_status -ne 0"] + styled(segment, "$__harbor_status", sep).map { "    " + $0 } + ["end"]
        case .jobs:
            return ["set -l __j (count (jobs -p))",
                    "if test $__j -gt 0"] + styled(segment, "'✦'$__j", sep).map { "    " + $0 } + ["end"]
        case .pythonEnvironment:
            return ["if set -q VIRTUAL_ENV"] + styled(segment, "'('(basename $VIRTUAL_ENV)')'", sep).map { "    " + $0 } + ["end"]
        }
    }

    private func styled(_ segment: PromptSegment, _ expression: String, _ separator: String) -> [String] {
        let color = fishColor(segment.color)
        guard color != "normal" || segment.bold else {
            return ["printf '%s%s' \(expression) \(separator)"]
        }
        return [
            "set_color \(segment.bold ? "-o " : "")\(color)",
            "printf '%s' \(expression)",
            "set_color normal",
            "printf '%s' \(separator)",
        ]
    }

    private func symbol(_ config: PromptConfig) -> [String] {
        [
            "if test $__harbor_status -eq 0",
            "    set_color \(fishColor(config.symbolColor))",
            "else",
            "    set_color \(fishColor(config.errorColor))",
            "end",
            "printf '%s ' \(quoted(config.symbol))",
            "set_color normal",
        ]
    }

    private func fishColor(_ color: PromptColor) -> String {
        switch color {
        case .default: "normal"
        case .black, .red, .green, .yellow, .blue, .magenta, .cyan, .white: color.rawValue
        default: "br" + color.rawValue.dropFirst("bright".count).lowercased()
        }
    }

    private func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}
