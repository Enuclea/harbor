import Foundation

/// A file or folder shown in the file flyout, local or remote.
public struct FileEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable, Hashable {
        case file, directory, symlink, other
    }

    public var id: String { path }
    public let name: String
    /// Absolute POSIX path on the side it lives on.
    public let path: String
    public let kind: Kind
    public let size: Int64?
    public let permissions: UInt32?
    public let modified: Date?

    public init(name: String, path: String, kind: Kind, size: Int64?, permissions: UInt32?, modified: Date?) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.permissions = permissions
        self.modified = modified
    }

    public var isDirectory: Bool { kind == .directory }
    public var isHidden: Bool { name.hasPrefix(".") }

    /// `rwxr-xr-x` style, for the info column.
    public var permissionString: String? {
        guard let permissions else { return nil }
        let symbols: [(UInt32, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        return String(symbols.map { permissions & $0.0 != 0 ? $0.1 : "-" })
    }

    /// Folders first, then case-insensitive natural order — like Finder.
    public static func finderOrder(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

/// POSIX path helpers for remote paths (which must never go through `URL`'s
/// local-filesystem semantics).
public enum RemotePath {
    public static func join(_ base: String, _ name: String) -> String {
        if base.isEmpty { return name }
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    public static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        return slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
    }

    public static func lastComponent(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path != "/" ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? "/"
    }

    /// Breadcrumbs: `/home/dan` → `[("/", "/"), ("home", "/home"), ("dan", "/home/dan")]`.
    public static func breadcrumbs(_ path: String) -> [(name: String, path: String)] {
        var crumbs: [(String, String)] = [("/", "/")]
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            crumbs.append((String(component), current))
        }
        return crumbs
    }
}
