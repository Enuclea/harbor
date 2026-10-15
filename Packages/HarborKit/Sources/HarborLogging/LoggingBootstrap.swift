import Foundation
import HarborCore

/// Wires the standard sinks once at launch.
public enum LoggingBootstrap {
    public struct Handles: Sendable {
        public let file: FileLogSink
        public let audit: AuditTrail
    }

    public static func configure(paths: AppPaths, level: LogLevel, feed: LogFeed?) -> Handles {
        let file = FileLogSink(directory: paths.logs)
        LogHub.shared.add(file)
        if let feed { LogHub.shared.add(feed.makeSink()) }
        LogHub.shared.minimumLevel = level
        return Handles(file: file, audit: AuditTrail(url: paths.auditLog))
    }

    /// Deletes session recordings and rotated logs older than `days`.
    public static func pruneOldFiles(in directories: [URL], olderThanDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let fileManager = FileManager.default
        for directory in directories {
            let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff, file.lastPathComponent != "harbor.jsonl", file.lastPathComponent != "audit.jsonl" {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
    }
}
