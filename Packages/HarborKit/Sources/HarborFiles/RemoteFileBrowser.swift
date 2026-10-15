import Foundation
import HarborCore
import HarborLogging
import HarborSSH

/// A remote host's filesystem over SFTP. Connects lazily and reconnects transparently
/// if the connection drops between operations.
public actor RemoteFileBrowser: FileBrowsing {
    public nonisolated let title: String
    public nonisolated let isRemote = true

    private let makeTransport: @Sendable () throws -> any SFTPTransport
    private var client: SFTPClient?
    private var cachedHome: String?
    private let log = Log(.sftp)

    public init(title: String, makeTransport: @escaping @Sendable () throws -> any SFTPTransport) {
        self.title = title
        self.makeTransport = makeTransport
    }

    /// A browser that rides the host's shared ssh connection.
    public static func ssh(host: HostProfile, builder: SSHCommandBuilder) -> RemoteFileBrowser {
        let command = builder.sftpSubsystem(host)
        return RemoteFileBrowser(title: host.name) { try ProcessSFTPTransport(command: command) }
    }

    public func disconnect() async {
        await client?.disconnect()
        client = nil
    }

    // MARK: FileBrowsing

    public func homeDirectory() async throws -> String {
        if let cachedHome { return cachedHome }
        let home = try await connected().realPath(".")
        cachedHome = home
        return home
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        try await connected().listDirectory(path).map { entry(for: $0, in: path) }
    }

    public func resolve(_ entry: FileEntry) async throws -> FileEntry {
        guard entry.kind == .symlink else { return entry }
        let attributes = try await connected().stat(entry.path)
        return FileEntry(name: entry.name, path: entry.path, kind: attributes.isDirectory ? .directory : .file,
                         size: attributes.size.map(Int64.init), permissions: attributes.permissions,
                         modified: entry.modified)
    }

    public func makeDirectory(_ path: String) async throws {
        try await connected().makeDirectory(path)
    }

    public func rename(_ path: String, to newPath: String) async throws {
        try await connected().rename(path, to: newPath)
    }

    public func delete(_ entry: FileEntry) async throws {
        let client = try await connected()
        if entry.isDirectory {
            for child in try await client.listDirectory(entry.path) {
                try await delete(self.entry(for: child, in: entry.path))
            }
            try await client.removeDirectory(entry.path)
        } else {
            try await client.removeFile(entry.path)
        }
    }

    public func copy(_ entry: FileEntry, to destination: URL, progress: @escaping TransferProgress) async throws {
        let client = try await connected()
        let resolved = try await resolve(entry)
        let total = resolved.isDirectory ? try await remoteSize(of: resolved.path) : resolved.size
        let counter = ProgressCounter(total: total, report: progress)
        try await copyDown(resolved, to: destination, client: client, counter: counter)
    }

    public func upload(_ localItem: URL, into directory: String, progress: @escaping TransferProgress) async throws {
        let client = try await connected()
        let counter = ProgressCounter(total: Self.localSize(of: localItem), report: progress)
        let existing = Set(try await client.listDirectory(directory).map(\.filename))
        var name = localItem.lastPathComponent
        if existing.contains(name) {
            name = UniqueName.remoteAvailable(for: name, existing: existing)
        }
        try await copyUp(localItem, to: RemotePath.join(directory, name), client: client, counter: counter)
    }

    // MARK: Recursion

    private func copyDown(_ entry: FileEntry, to destination: URL, client: SFTPClient, counter: ProgressCounter) async throws {
        try Task.checkCancellation()
        if entry.isDirectory {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for child in try await client.listDirectory(entry.path) {
                let childEntry = try await resolve(self.entry(for: child, in: entry.path))
                try await copyDown(childEntry, to: destination.appending(path: child.filename), client: client, counter: counter)
            }
        } else {
            let base = counter.completed
            try await client.download(entry.path, to: destination) { done, _ in counter.set(base + done) }
        }
    }

    private func copyUp(_ local: URL, to remotePath: String, client: SFTPClient, counter: ProgressCounter) async throws {
        try Task.checkCancellation()
        let values = try local.resourceValues(forKeys: [.isDirectoryKey])
        let permissions = (try? FileManager.default.attributesOfItem(atPath: local.path)[.posixPermissions] as? NSNumber)?.uint32Value
        if values.isDirectory == true {
            try await client.makeDirectory(remotePath, permissions: permissions ?? 0o755)
            for child in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) {
                try await copyUp(child, to: RemotePath.join(remotePath, child.lastPathComponent), client: client, counter: counter)
            }
        } else {
            let base = counter.completed
            try await client.upload(local, to: remotePath, permissions: permissions) { done, _ in counter.set(base + done) }
        }
    }

    private func remoteSize(of path: String) async throws -> Int64 {
        var total: Int64 = 0
        for child in try await connected().listDirectory(path) {
            if child.attributes.isDirectory {
                total += try await remoteSize(of: RemotePath.join(path, child.filename))
            } else {
                total += Int64(child.attributes.size ?? 0)
            }
        }
        return total
    }

    // MARK: Helpers

    func connected() async throws -> SFTPClient {
        if let client, await client.isOpen { return client }
        let client = SFTPClient(transport: try makeTransport())
        do {
            try await client.connect()
        } catch {
            log.warning("sftp connect to \(title) failed: \(error.localizedDescription)")
            throw error
        }
        self.client = client
        return client
    }

    private func entry(for name: SFTPName, in directory: String) -> FileEntry {
        let attributes = name.attributes
        let kind: FileEntry.Kind = attributes.isDirectory ? .directory
            : attributes.isSymlink ? .symlink
            : attributes.isRegularFile || attributes.fileType == nil ? .file : .other
        return FileEntry(
            name: name.filename, path: RemotePath.join(directory, name.filename), kind: kind,
            size: attributes.size.map(Int64.init), permissions: attributes.permissions.map { $0 & 0o7777 },
            modified: attributes.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }
}

/// Aggregates per-file progress into one running total.
final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    let total: Int64?
    let report: TransferProgress

    init(total: Int64?, report: @escaping TransferProgress) {
        self.total = total
        self.report = report
    }

    var completed: Int64 { lock.withLock { value } }

    func set(_ completed: Int64) {
        lock.withLock { value = completed }
        report(completed, total)
    }
}

extension UniqueName {
    static func remoteAvailable(for name: String, existing: Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 2...999 {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !existing.contains(candidate) { return candidate }
        }
        return "\(base)-\(UUID().uuidString.prefix(8))\(ext.isEmpty ? "" : ".\(ext)")"
    }
}
