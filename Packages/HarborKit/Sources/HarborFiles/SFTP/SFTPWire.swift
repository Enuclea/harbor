import Foundation

/// Big-endian encoder for SFTP packet payloads.
struct SFTPWriter {
    private(set) var data = Data()

    mutating func byte(_ value: UInt8) {
        data.append(value)
    }

    mutating func uint32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func uint64(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func string(_ value: String) {
        bytes(Data(value.utf8))
    }

    /// An SFTP "string": uint32 length followed by raw bytes.
    mutating func bytes(_ value: Data) {
        uint32(UInt32(value.count))
        data.append(value)
    }

    mutating func attributes(_ value: SFTPAttributes) {
        value.encode(into: &self)
    }

    /// Wraps `payload` in a length-prefixed packet of `type`.
    static func packet(type: SFTPPacketType, _ build: (inout SFTPWriter) -> Void) -> Data {
        var body = SFTPWriter()
        body.byte(type.rawValue)
        build(&body)
        var framed = SFTPWriter()
        framed.uint32(UInt32(body.data.count))
        framed.data.append(body.data)
        return framed.data
    }
}

enum SFTPWireError: Error {
    case truncated
}

/// Big-endian decoder over one packet's payload.
struct SFTPReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }

    mutating func byte() throws -> UInt8 {
        guard offset < data.endIndex else { throw SFTPWireError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func uint32() throws -> UInt32 {
        try fixedWidth(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func uint64() throws -> UInt64 {
        try fixedWidth(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    mutating func bytes() throws -> Data {
        let length = Int(try uint32())
        return try fixedWidth(length)
    }

    mutating func string() throws -> String {
        String(decoding: try bytes(), as: UTF8.self)
    }

    private mutating func fixedWidth(_ count: Int) throws -> Data {
        guard count >= 0, data.endIndex - offset >= count else { throw SFTPWireError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
}
