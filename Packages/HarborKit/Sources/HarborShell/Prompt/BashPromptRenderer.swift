import Foundation
import HarborCore

struct BashPromptRenderer: PromptRenderer {
    func render(_ config: PromptConfig) -> String {
        let kinds = Set(config.segments.map(\.kind))
        var lines = [PromptBuilder.header(for: config), ""]
        if kinds.contains(.pythonEnvironment) {
            lines.append("export VIRTUAL_ENV_DISABLE_PROMPT=1")
        }

        // Called by Harbor's integration (which captures $? first) or by the hook below.
        lines.append("__harbor_prompt_build() {")
        lines.append("  local __s=${1:-$?}")
        for segment in config.segments where segment.kind.isDynamic {
            lines += assignment(for: segment, separator: config.separator).map { "  " + $0 }
        }
        lines += symbolAssignment(config).map { "  " + $0 }
        lines.append("  return $__s")
        lines.append("}")

        let body = config.segments.map { piece(for: $0, separator: config.separator) }.joined()
        let symbol = "${__harbor_p_sym}\(ps1Literal(config.symbol))\\[\\e[0m\\] "
        let prompt = config.layout == .twoLine ? body + "\\n" + symbol : body + symbol
        lines.append("PS1='\(prompt)'")
        lines += [
            "",
            "if [[ -z \"${_HARBOR_INTEGRATION_LOADED-}\" && \"$PROMPT_COMMAND\" != *__harbor_prompt_command* ]]; then",
            "  __harbor_prompt_command() { __harbor_prompt_build \"$?\"; }",
            "  if [[ \"$(declare -p PROMPT_COMMAND 2>/dev/null)\" == \"declare -a\"* ]]; then",
            "    PROMPT_COMMAND=(__harbor_prompt_command \"${PROMPT_COMMAND[@]}\")",
            "  else",
            "    PROMPT_COMMAND=\"__harbor_prompt_command${PROMPT_COMMAND:+; $PROMPT_COMMAND}\"",
            "  fi",
            "fi",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Pieces

    /// Static segments use bash prompt escapes inside the single-quoted PS1.
    private func piece(for segment: PromptSegment, separator: String) -> String {
        let sep = ps1Literal(separator)
        switch segment.kind {
        case .user: return staticStyle(segment, "\\u") + sep
        case .host: return staticStyle(segment, "\\h") + sep
        case .userAtHost: return staticStyle(segment, "\\u@\\h") + sep
        case .directory: return staticStyle(segment, "\\w") + sep
        case .directoryName: return staticStyle(segment, "\\W") + sep
        case .time: return staticStyle(segment, "\\t") + sep
        case .gitBranch: return "${__harbor_p_git}"
        case .exitStatus: return "${__harbor_p_exit}"
        case .jobs: return "${__harbor_p_jobs}"
        case .pythonEnvironment: return "${__harbor_p_venv}"
        }
    }

    private func assignment(for segment: PromptSegment, separator: String) -> [String] {
        let tail = "$'\\001\\e[0m\\002'" + "'\(singleQuoted(separator))'"
        let open = dynamicOpen(segment)
        switch segment.kind {
        case .gitBranch:
            return [
                "local __b; __b=$(command git symbolic-ref --short HEAD 2>/dev/null || command git rev-parse --short HEAD 2>/dev/null)",
                "__harbor_p_git=''; [[ -n $__b ]] && __harbor_p_git=\(open)\"$__b\"\(tail)",
            ]
        case .exitStatus:
            return ["__harbor_p_exit=''; [[ $__s != 0 ]] && __harbor_p_exit=\(open)\"$__s\"\(tail)"]
        case .jobs:
            return [
                "local __j; __j=$(jobs -p | wc -l); __j=${__j//[!0-9]/}",
                "__harbor_p_jobs=''; (( ${__j:-0} > 0 )) && __harbor_p_jobs=\(open)\"✦$__j\"\(tail)",
            ]
        case .pythonEnvironment:
            return ["__harbor_p_venv=''; [[ -n $VIRTUAL_ENV ]] && __harbor_p_venv=\(open)\"(${VIRTUAL_ENV##*/})\"\(tail)"]
        default:
            return []
        }
    }

    private func symbolAssignment(_ config: PromptConfig) -> [String] {
        let ok = "$'\\001\(sgr(color: config.symbolColor, bold: false))\\002'"
        let failed = "$'\\001\(sgr(color: config.errorColor, bold: false))\\002'"
        return ["if [[ $__s == 0 ]]; then __harbor_p_sym=\(ok); else __harbor_p_sym=\(failed); fi"]
    }

    // MARK: Styling

    private func staticStyle(_ segment: PromptSegment, _ text: String) -> String {
        let codes = sgr(color: segment.color, bold: segment.bold)
        return codes.isEmpty ? text : "\\[\(codes)\\]\(text)\\[\\e[0m\\]"
    }

    private func dynamicOpen(_ segment: PromptSegment) -> String {
        "$'\\001\(sgr(color: segment.color, bold: segment.bold))\\002'"
    }

    /// Select Graphic Rendition escapes using palette indices so the theme applies.
    private func sgr(color: PromptColor, bold: Bool) -> String {
        var codes = bold ? "\\e[1m" : ""
        if let index = color.ansiIndex {
            codes += index < 8 ? "\\e[3\(index)m" : "\\e[9\(index - 8)m"
        }
        return codes
    }

    /// Text placed inside the single-quoted PS1: prompt-escape characters are neutralised
    /// (backslash doubled, `$` and backtick as octal escapes) before shell quoting.
    private func ps1Literal(_ text: String) -> String {
        let neutralised = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$", with: "\\044")
            .replacingOccurrences(of: "`", with: "\\140")
        return singleQuoted(neutralised)
    }

    /// Plain shell single-quoting for values assigned to variables.
    private func singleQuoted(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "'\\''")
    }
}
