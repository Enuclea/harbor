import Foundation
import HarborCore

/// Records a session's output to disk as plain text or asciicast v2.
///
/// Only output is recorded — never keystrokes — so typed passwords can't end up in a file.
/// All work happens on a private queue; `record` is safe to call from the PTY read queue.
public final class SessionRecorder: @unchecked Sendable {
    public enum Format: Sendable {
        case text, asciicast
    }

    public let fileURL: URL
    private let format: Format
    private let queue = DispatchQueue(label: "harbor.session-recorder", qos: .utility)
    private let handle: FileHandle
    private let startedAt = Date()
    private var stripper = ANSIStripper()
    private var decoder = UTF8StreamDecoder()
    private var closed = false

    public init(directory: URL, title: String, format: Format, size: TerminalSize, environment: [String: String]) throws {
        self.format = format
        let stamp = Self.fileStamp.string(from: startedAt)
        let safeTitle = title.components(separatedBy: CharacterSet(charactersIn: "/:\\\n")).joined(separator: "-").prefix(60)
        let fileExtension = format == .asciicast ? "cast" : "txt"
        fileURL = directory.appending(path: "\(stamp) \(safeTitle).\(fileExtension)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        handle = try FileHandle(forWritingTo: fileURL)

        if format == .asciicast {
            let header: [String: Any] = [
                "version": 2,
                "width": size.columns,
                "height": size.rows,
                "timestamp": Int(startedAt.timeIntervalSince1970),
                "title": title,
                "env": ["TERM": environment["TERM"] ?? "xterm-256color", "SHELL": environment["SHELL"] ?? ""],
            ]
            writeJSONLine(header)
        }
    }

    public func record(output data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            switch format {
            case .text:
                let text = stripper.strip(data)
                if !text.isEmpty { try? handle.write(contentsOf: Data(text.utf8)) }
            case .asciicast:
                let text = decoder.decode(data)
                if !text.isEmpty { writeJSONLine([elapsed, "o", text]) }
            }
        }
    }

    public func record(resize size: TerminalSize) {
        guard format == .asciicast else { return }
        queue.async { [self] in
            guard !closed else { return }
            writeJSONLine([elapsed, "r", "\(size.columns)x\(size.rows)"])
        }
    }

    public func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            if format == .text {
                let tail = stripper.finish()
                if !tail.isEmpty { try? handle.write(contentsOf: Data(tail.utf8)) }
            }
            try? handle.synchronize()
            try? handle.close()
        }
    }

    private var elapsed: Double {
        (Date().timeIntervalSince(startedAt) * 1_000).rounded() / 1_000
    }

    private func writeJSONLine(_ object: Any) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}
