import Foundation

/// What the file flyout needs from a filesystem. Implemented for the local Mac and for
/// remote hosts over SFTP, so the UI is identical for both.
public protocol FileBrowsing: Sendable {
    var title: String { get }
    var isRemote: Bool { get }

    func homeDirectory() async throws -> String
    func list(_ path: String) async throws -> [FileEntry]
    /// Follows a symlink so the UI can tell whether it points at a folder.
    func resolve(_ entry: FileEntry) async throws -> FileEntry
    func makeDirectory(_ path: String) async throws
    func rename(_ path: String, to newPath: String) async throws
    /// Deletes a file, or a folder and everything in it.
    func delete(_ entry: FileEntry) async throws
    /// Copies `entry` (recursively for folders) to exactly `destination` on this Mac.
    /// Used for Finder drags, where Finder chooses the destination path.
    func copy(_ entry: FileEntry, to destination: URL, progress: @escaping TransferProgress) async throws
    /// Copies a local file or folder into `directory`.
    func upload(_ localItem: URL, into directory: String, progress: @escaping TransferProgress) async throws
}

extension FileBrowsing {
    /// Copies `entry` into a local directory under a non-colliding name, returning the new item.
    public func download(_ entry: FileEntry, into localDirectory: URL, progress: @escaping TransferProgress) async throws -> URL {
        let destination = UniqueName.available(for: entry.name, in: localDirectory)
        try await copy(entry, to: destination, progress: progress)
        return destination
    }

    /// Total bytes in a local file or folder, for progress reporting.
    static func localSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var total = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}
