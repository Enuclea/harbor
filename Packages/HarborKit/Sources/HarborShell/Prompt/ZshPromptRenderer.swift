import Foundation
import HarborCore

struct ZshPromptRenderer: PromptRenderer {
    func render(_ config: PromptConfig) -> String {
        let kinds = Set(config.segments.map(\.kind))
        var lines = [PromptBuilder.header(for: config), "", "setopt prompt_subst"]

        if kinds.contains(.gitBranch) {
            lines += [
                "autoload -Uz vcs_info",
                "zstyle ':vcs_info:*' enable git",
                "zstyle ':vcs_info:git:*' formats '%b'",
                "zstyle ':vcs_info:git:*' actionformats '%b|%a'",
            ]
        }
        if kinds.contains(.pythonEnvironment) {
            lines.append("export VIRTUAL_ENV_DISABLE_PROMPT=1")
        }

        let dynamic = config.segments.filter { $0.kind.isDynamic }
        if !dynamic.isEmpty {
            lines.append("")
            lines.append("_harbor_prompt_precmd() {")
            lines.append("  local -i __s=$?")
            for segment in dynamic {
                lines += assignment(for: segment, separator: config.separator).map { "  " + $0 }
            }
            lines.append("  return __s")
            lines.append("}")
            lines.append("typeset -ga precmd_functions")
            lines.append("precmd_functions=(${precmd_functions:#_harbor_prompt_precmd} _harbor_prompt_precmd)")
        }

        let body = config.segments.map { piece(for: $0, separator: config.separator) }.joined()
        let symbol = symbolText(config)
        let prompt = config.layout == .twoLine ? body + "\n" + symbol : body + symbol
        lines.append("")
        lines.append("PROMPT='\(singleQuoted(prompt))'")
        lines.append("RPROMPT=''")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Pieces

    private func piece(for segment: PromptSegment, separator: String) -> String {
        let sep = promptEscaped(separator)
        switch segment.kind {
        case .user: return style(segment, "%n") + sep
        case .host: return style(segment, "%m") + sep
        case .userAtHost: return style(segment, "%n@%m") + sep
        case .directory: return style(segment, "%~") + sep
        case .directoryName: return style(segment, "%1~") + sep
        case .time: return style(segment, "%*") + sep
        case .gitBranch: return "${_harbor_p_git}"
        case .exitStatus: return "${_harbor_p_exit}"
        case .jobs: return "${_harbor_p_jobs}"
        case .pythonEnvironment: return "${_harbor_p_venv}"
        }
    }

    /// Lines for the precmd function. Values are already prompt-escaped (`%` doubled).
    private func assignment(for segment: PromptSegment, separator: String) -> [String] {
        let sep = doubleQuoted(promptEscaped(separator))
        switch segment.kind {
        case .gitBranch:
            return [
                "vcs_info 2>/dev/null",
                "_harbor_p_git=\"\"",
                "[[ -n $vcs_info_msg_0_ ]] && _harbor_p_git=\"\(style(segment, "${vcs_info_msg_0_//\\%/%%}"))\(sep)\"",
            ]
        case .exitStatus:
            return ["_harbor_p_exit=\"\"", "(( __s != 0 )) && _harbor_p_exit=\"\(style(segment, "$__s"))\(sep)\""]
        case .jobs:
            return [
                "local -i __j=${(%):-%j}",
                "_harbor_p_jobs=\"\"",
                "(( __j > 0 )) && _harbor_p_jobs=\"\(style(segment, "✦$__j"))\(sep)\"",
            ]
        case .pythonEnvironment:
            return [
                "_harbor_p_venv=\"\"",
                "[[ -n $VIRTUAL_ENV ]] && _harbor_p_venv=\"\(style(segment, "(${${VIRTUAL_ENV:t}//\\%/%%})"))\(sep)\"",
            ]
        default:
            return []
        }
    }

    private func symbolText(_ config: PromptConfig) -> String {
        let symbol = promptEscaped(config.symbol) + " "
        switch (config.symbolColor.ansiIndex, config.errorColor.ansiIndex) {
        case (nil, nil): return symbol
        case (let ok?, let failed?): return "%(?.%F{\(ok)}.%F{\(failed)})\(symbol)%f"
        case (let ok?, nil): return "%(?.%F{\(ok)}.)\(symbol)%f"
        case (nil, let failed?): return "%(?..%F{\(failed)})\(symbol)%f"
        }
    }

    private func style(_ segment: PromptSegment, _ text: String) -> String {
        var result = text
        if let index = segment.color.ansiIndex { result = "%F{\(index)}\(result)%f" }
        if segment.bold { result = "%B\(result)%b" }
        return result
    }

    // MARK: Escaping

    private func promptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "%", with: "%%")
    }

    private func singleQuoted(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "'\\''")
    }

    private func doubleQuoted(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\\"$`".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
