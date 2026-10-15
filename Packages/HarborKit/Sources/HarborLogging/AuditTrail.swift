import Foundation
import HarborCore

/// One security-relevant action taken by something other than the person at the keyboard:
/// an AI assistant over MCP, or a browser over remote access.
public struct AuditRecord: Codable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case allowed, denied, failed
    }

    public var id = UUID()
    public let date: Date
    /// Who acted, e.g. `mcp:claude-desktop` or `web:203.0.113.7`.
    public let actor: String
    /// What they did, e.g. `send_input`, `login`, `open_session`.
    public let action: String
    /// What it was done to, e.g. a session title.
    public let target: String?
    /// Short, already-redacted detail such as the command typed.
    public let detail: String?
    public let outcome: Outcome

    public init(actor: String, action: String, target: String? = nil, detail: String? = nil, outcome: Outcome, date: Date = Date()) {
        self.date = date
        self.actor = actor
        self.action = action
        self.target = target
        self.detail = detail.map { Redactor.redact(String($0.prefix(500))) }
        self.outcome = outcome
    }
}

/// Append-only JSONL audit log (`~/Library/Logs/Harbor/audit.jsonl`), mirrored to the main log.
public final class AuditTrail: Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "harbor.audit", qos: .utility)
    private let log = Log(.control)

    public init(url: URL) {
        self.url = url
    }

    public func record(_ record: AuditRecord) {
        log.notice("audit \(record.action) by \(record.actor): \(record.outcome.rawValue)", [
            "target": record.target ?? "-",
        ])
        queue.async { [url] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard var line = try? encoder.encode(record) else { return }
            line.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    /// Most recent records first; used by the AI & Remote panels.
    public func recent(limit: Int = 200) -> [AuditRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).suffix(limit).reversed().compactMap {
            try? decoder.decode(AuditRecord.self, from: Data($0))
        }
    }
}
