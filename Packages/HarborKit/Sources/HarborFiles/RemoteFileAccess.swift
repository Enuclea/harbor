import Foundation

/// Small-file access on a remote host, used to install and edit configuration there.
public protocol RemoteFileAccess: Sendable {
    func homeDirectory() async throws -> String
    /// The file's contents, or nil when it doesn't exist.
    func readFile(_ path: String) async throws -> Data?
    /// Writes `contents`, keeping the existing permissions when `permissions` is nil
    /// (new files get `0644`).
    func writeFile(_ path: String, contents: Data, permissions: UInt32?) async throws
    /// Creates the directory if it's missing (the parent must exist).
    func ensureDirectory(_ path: String, permissions: UInt32) async throws
    /// Deletes a file or folder; succeeds if it's already gone.
    func removeItem(_ path: String) async throws
    func itemExists(_ path: String) async throws -> Bool
}

extension RemoteFileBrowser: RemoteFileAccess {
    public func readFile(_ path: String) async throws -> Data? {
        do {
            return try await connected().readFile(path)
        } catch SFTPError.status(.noSuchFile, _) {
            return nil
        }
    }

    public func writeFile(_ path: String, contents: Data, permissions: UInt32?) async throws {
        let client = try await connected()
        var mode = permissions
        if mode == nil {
            mode = (try? await client.stat(path))?.permissions.map { $0 & 0o7777 }
        }
        try await client.writeFile(path, contents: contents, permissions: mode ?? 0o644)
    }

    public func ensureDirectory(_ path: String, permissions: UInt32) async throws {
        let client = try await connected()
        if let attributes = try? await client.stat(path), attributes.isDirectory { return }
        try await client.makeDirectory(path, permissions: permissions)
    }

    public func itemExists(_ path: String) async throws -> Bool {
        (try? await connected().lstat(path)) != nil
    }

    public func removeItem(_ path: String) async throws {
        let client = try await connected()
        guard let attributes = try? await client.lstat(path) else { return }
        let entry = FileEntry(name: RemotePath.lastComponent(path), path: path,
                              kind: attributes.isDirectory ? .directory : .file,
                              size: nil, permissions: attributes.permissions, modified: nil)
        try await delete(entry)
    }
}
