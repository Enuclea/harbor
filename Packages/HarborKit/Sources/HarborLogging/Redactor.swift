import Foundation

/// Removes likely secrets from text before it is written to audit logs, support bundles
/// or sent to an assistant. Conservative by design: it is a safety net, not a guarantee.
public enum Redactor {
    private static let rules: [(NSRegularExpression, String)] = [
        // -----BEGIN … PRIVATE KEY----- blocks
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "<redacted private key>"),
        // password=…, token: …, api_key=…
        (#"(?i)\b(pass(?:word|wd)?|secret|token|api[_-]?key|access[_-]?key|auth)\b(\s*[=:]\s*)("[^"]*"|'[^']*'|\S+)"#, "$1$2<redacted>"),
        // Authorization: Bearer …
        (#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 <redacted>"),
        // scheme://user:password@host
        (#"([a-zA-Z][a-zA-Z0-9+.-]*://[^\s:/@]+):[^\s@/]+@"#, "$1:<redacted>@"),
        // AWS access key ids
        (#"\bAKIA[0-9A-Z]{16}\b"#, "<redacted aws key>"),
        // GitHub / Anthropic / OpenAI-style tokens
        (#"\b(gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,})\b"#, "<redacted token>"),
    ].compactMap { pattern, template in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
    }

    public static func redact(_ text: String) -> String {
        var result = text
        for (expression, template) in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}
