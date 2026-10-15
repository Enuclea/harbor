import Foundation

/// Loads and saves one Codable document as a private (`0600`) JSON file with atomic writes.
public struct JSONFileStore<Value: Codable & Sendable>: Sendable {
    public let url: URL
    private let defaults: @Sendable () -> Value

    public init(url: URL, defaults: @escaping @Sendable () -> Value) {
        self.url = url
        self.defaults = defaults
    }

    /// Returns the stored value, or defaults when the file is missing.
    /// A corrupt file is moved aside (never silently overwritten) and defaults are returned.
    public func load() -> LoadResult {
        guard let data = try? Data(contentsOf: url) else {
            return LoadResult(value: defaults(), recoveredFrom: nil)
        }
        do {
            return LoadResult(value: try LenientJSON.decode(Value.self, from: data, defaults: defaults()), recoveredFrom: nil)
        } catch {
            let backup = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return LoadResult(value: defaults(), recoveredFrom: CorruptFile(backupURL: backup, error: error.localizedDescription))
        }
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.harbor.encode(value)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public struct LoadResult: Sendable {
        public let value: Value
        public let recoveredFrom: CorruptFile?
    }

    public struct CorruptFile: Sendable {
        public let backupURL: URL
        public let error: String
    }
}
