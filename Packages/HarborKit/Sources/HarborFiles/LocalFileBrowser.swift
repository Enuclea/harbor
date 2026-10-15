import Foundation

/// The Mac's own filesystem, used by the flyout in local terminal tabs.
public struct LocalFileBrowser: FileBrowsing {
    public let title = "This Mac"
    public let isRemote = false

    public init() {}

    public func homeDirectory() async throws -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let kind: FileEntry.Kind = values?.isSymbolicLink == true ? .symlink : (values?.isDirectory == true ? .directory : .file)
            return FileEntry(
                name: url.lastPathComponent, path: url.path, kind: kind,
                size: values?.fileSize.map(Int64.init), permissions: (attributes?[.posixPermissions] as? NSNumber)?.uint32Value,
                modified: values?.contentModificationDate)
        }
    }

    public func resolve(_ entry: FileEntry) async throws -> FileEntry {
        guard entry.kind == .symlink else { return entry }
        let resolved = URL(fileURLWithPath: entry.path).resolvingSymlinksInPath()
        let isDirectory = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return FileEntry(name: entry.name, path: entry.path, kind: isDirectory ? .directory : .file,
                         size: entry.size, permissions: entry.permissions, modified: entry.modified)
    }

    public func makeDirectory(_ path: String) async throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    public func rename(_ path: String, to newPath: String) async throws {
        try FileManager.default.moveItem(atPath: path, toPath: newPath)
    }

    /// Moves to the Trash rather than deleting, matching Finder.
    public func delete(_ entry: FileEntry) async throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
    }

    public func copy(_ entry: FileEntry, to destination: URL, progress: @escaping TransferProgress) async throws {
        try FileManager.default.copyItem(at: URL(fileURLWithPath: entry.path), to: destination)
        let size = Self.localSize(of: destination)
        progress(size, size)
    }

    public func upload(_ localItem: URL, into directory: String, progress: @escaping TransferProgress) async throws {
        let destination = UniqueName.available(for: localItem.lastPathComponent, in: URL(fileURLWithPath: directory, isDirectory: true))
        try FileManager.default.copyItem(at: localItem, to: destination)
        let size = Self.localSize(of: destination)
        progress(size, size)
    }
}

/// Finder-style "name 2.txt" collision avoidance.
public enum UniqueName {
    public static func available(for name: String, in directory: URL) -> URL {
        let candidate = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 2...999 {
            let next = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let url = directory.appending(path: next)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return directory.appending(path: "\(base) \(UUID().uuidString.prefix(8))\(ext.isEmpty ? "" : ".\(ext)")")
    }
}
