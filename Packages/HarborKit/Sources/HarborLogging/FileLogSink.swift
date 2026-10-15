import Foundation
import HarborCore

/// Appends entries as JSON Lines to `~/Library/Logs/Harbor/harbor.jsonl`, rotating to
/// `harbor.1.jsonl … harbor.N.jsonl` by size. Writes happen on a private utility queue.
public final class FileLogSink: LogSink, @unchecked Sendable {
    public let directory: URL
    private let baseName: String
    private let maximumBytes: UInt64
    private let maximumFiles: Int
    private let queue = DispatchQueue(label: "harbor.log.file", qos: .utility)
    private let encoder: JSONEncoder
    private var handle: FileHandle?
    private var currentSize: UInt64 = 0

    public init(directory: URL, baseName: String = "harbor", maximumBytes: UInt64 = 5_000_000, maximumFiles: Int = 5) {
        self.directory = directory
        self.baseName = baseName
        self.maximumBytes = maximumBytes
        self.maximumFiles = maximumFiles
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder
    }

    public var currentFileURL: URL { fileURL(index: 0) }

    /// All log files, newest first.
    public var allFileURLs: [URL] {
        (0...maximumFiles).map(fileURL(index:)).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func write(_ entry: LogEntry) {
        queue.async { self.append(entry) }
    }

    /// Blocks until queued entries are on disk.
    public func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private func append(_ entry: LogEntry) {
        guard var line = try? encoder.encode(Line(entry)) else { return }
        line.append(0x0A)
        do {
            let handle = try openIfNeeded()
            try handle.write(contentsOf: line)
            currentSize += UInt64(line.count)
            if currentSize >= maximumBytes { rotate() }
        } catch {
            self.handle = nil
        }
    }

    private func openIfNeeded() throws -> FileHandle {
        if let handle { return handle }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = currentFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        currentSize = try handle.seekToEnd()
        self.handle = handle
        return handle
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: fileURL(index: maximumFiles))
        for index in stride(from: maximumFiles - 1, through: 0, by: -1) {
            let source = fileURL(index: index)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.moveItem(at: source, to: fileURL(index: index + 1))
        }
        currentSize = 0
    }

    private func fileURL(index: Int) -> URL {
        directory.appending(path: index == 0 ? "\(baseName).jsonl" : "\(baseName).\(index).jsonl")
    }

    /// Compact on-disk representation.
    private struct Line: Encodable {
        let t: Date
        let l: String
        let c: String
        let m: String
        let meta: [String: String]?

        init(_ entry: LogEntry) {
            t = entry.date
            l = entry.level.rawValue
            c = entry.category.rawValue
            m = entry.message
            meta = entry.metadata.isEmpty ? nil : entry.metadata
        }
    }
}
