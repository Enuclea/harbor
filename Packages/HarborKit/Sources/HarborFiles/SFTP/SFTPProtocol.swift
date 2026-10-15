import Foundation

/// SFTP protocol version 3 (draft-ietf-secsh-filexfer-02), as spoken by OpenSSH.
enum SFTPPacketType: UInt8 {
    case initialize = 1, version = 2
    case open = 3, close = 4, read = 5, write = 6, lstat = 7, fstat = 8, setstat = 9, fsetstat = 10
    case opendir = 11, readdir = 12, remove = 13, mkdir = 14, rmdir = 15, realpath = 16, stat = 17
    case rename = 18, readlink = 19, symlink = 20
    case status = 101, handle = 102, data = 103, name = 104, attrs = 105
}

public struct SFTPOpenFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read = SFTPOpenFlags(rawValue: 0x01)
    public static let write = SFTPOpenFlags(rawValue: 0x02)
    public static let append = SFTPOpenFlags(rawValue: 0x04)
    public static let create = SFTPOpenFlags(rawValue: 0x08)
    public static let truncate = SFTPOpenFlags(rawValue: 0x10)
    public static let exclusive = SFTPOpenFlags(rawValue: 0x20)
}

public enum SFTPStatusCode: UInt32, Sendable {
    case ok = 0, endOfFile, noSuchFile, permissionDenied, failure, badMessage, noConnection, connectionLost, unsupported
}

/// File attributes. Every field is optional because servers only send what they know.
public struct SFTPAttributes: Sendable, Equatable {
    public var size: UInt64?
    public var uid: UInt32?
    public var gid: UInt32?
    public var permissions: UInt32?
    public var accessTime: UInt32?
    public var modificationTime: UInt32?

    public init(size: UInt64? = nil, permissions: UInt32? = nil, modificationTime: UInt32? = nil) {
        self.size = size
        self.permissions = permissions
        self.modificationTime = modificationTime
    }

    private enum Flag {
        static let size: UInt32 = 0x01
        static let uidgid: UInt32 = 0x02
        static let permissions: UInt32 = 0x04
        static let times: UInt32 = 0x08
        static let extended: UInt32 = 0x8000_0000
    }

    /// POSIX file-type bits (`S_IFMT`).
    public var fileType: UInt32? { permissions.map { $0 & 0o170000 } }
    public var isDirectory: Bool { fileType == 0o040000 }
    public var isSymlink: Bool { fileType == 0o120000 }
    public var isRegularFile: Bool { fileType == 0o100000 }

    func encode(into writer: inout SFTPWriter) {
        var flags: UInt32 = 0
        if size != nil { flags |= Flag.size }
        if uid != nil, gid != nil { flags |= Flag.uidgid }
        if permissions != nil { flags |= Flag.permissions }
        if accessTime != nil || modificationTime != nil { flags |= Flag.times }
        writer.uint32(flags)
        if let size { writer.uint64(size) }
        if let uid, let gid { writer.uint32(uid); writer.uint32(gid) }
        if let permissions { writer.uint32(permissions) }
        if flags & Flag.times != 0 {
            writer.uint32(accessTime ?? modificationTime ?? 0)
            writer.uint32(modificationTime ?? accessTime ?? 0)
        }
    }

    static func decode(from reader: inout SFTPReader) throws -> SFTPAttributes {
        var attributes = SFTPAttributes()
        let flags = try reader.uint32()
        if flags & Flag.size != 0 { attributes.size = try reader.uint64() }
        if flags & Flag.uidgid != 0 {
            attributes.uid = try reader.uint32()
            attributes.gid = try reader.uint32()
        }
        if flags & Flag.permissions != 0 { attributes.permissions = try reader.uint32() }
        if flags & Flag.times != 0 {
            attributes.accessTime = try reader.uint32()
            attributes.modificationTime = try reader.uint32()
        }
        if flags & Flag.extended != 0 {
            for _ in 0..<(try reader.uint32()) {
                _ = try reader.bytes()
                _ = try reader.bytes()
            }
        }
        return attributes
    }
}

/// One `NAME` record.
public struct SFTPName: Sendable, Equatable {
    public let filename: String
    public let longname: String
    public let attributes: SFTPAttributes
}

/// A decoded server response.
enum SFTPResponse: Sendable {
    case version(UInt32)
    case status(SFTPStatusCode, message: String)
    case handle(Data)
    case data(Data)
    case names([SFTPName])
    case attributes(SFTPAttributes)

    /// Decodes one packet body (type byte onward). Returns the request id (0 for VERSION).
    static func decode(_ packet: Data) throws -> (id: UInt32, response: SFTPResponse) {
        var reader = SFTPReader(packet)
        guard let type = SFTPPacketType(rawValue: try reader.byte()) else { throw SFTPError.protocolViolation("unknown packet type") }
        if type == .version { return (0, .version(try reader.uint32())) }
        let id = try reader.uint32()
        switch type {
        case .status:
            let rawCode = try reader.uint32()
            let message = reader.isAtEnd ? "" : try reader.string()
            return (id, .status(SFTPStatusCode(rawValue: rawCode) ?? .failure, message: message))
        case .handle:
            return (id, .handle(try reader.bytes()))
        case .data:
            return (id, .data(try reader.bytes()))
        case .name:
            let count = try reader.uint32()
            var names: [SFTPName] = []
            names.reserveCapacity(Int(min(count, 4_096)))
            for _ in 0..<count {
                let filename = try reader.string()
                let longname = try reader.string()
                let attributes = try SFTPAttributes.decode(from: &reader)
                names.append(SFTPName(filename: filename, longname: longname, attributes: attributes))
            }
            return (id, .names(names))
        case .attrs:
            return (id, .attributes(try SFTPAttributes.decode(from: &reader)))
        default:
            throw SFTPError.protocolViolation("unexpected packet type \(type)")
        }
    }
}

public enum SFTPError: Error, LocalizedError, Equatable {
    case status(SFTPStatusCode, String)
    case protocolViolation(String)
    case disconnected(String)
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .status(.noSuchFile, _): "No such file or folder."
        case .status(.permissionDenied, _): "Permission denied."
        case .status(_, let message): message.isEmpty ? "The server reported an error." : message
        case .protocolViolation(let detail): "The server sent an invalid response (\(detail))."
        case .disconnected(let detail): detail.isEmpty ? "The connection to the server closed." : detail
        case .unexpectedResponse: "The server sent an unexpected response."
        }
    }
}
