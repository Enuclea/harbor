import Foundation

/// Decodes UTF-8 that arrives in arbitrary chunks, holding back an incomplete trailing
/// sequence until the next chunk instead of emitting replacement characters.
public struct UTF8StreamDecoder: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    public mutating func decode(_ data: Data) -> String {
        var bytes = pending
        bytes.append(contentsOf: data)
        let split = Self.completePrefixLength(bytes)
        pending = Array(bytes[split...])
        return String(decoding: bytes[..<split], as: UTF8.self)
    }

    /// Returns whatever is pending, even if incomplete. Call when the stream ends.
    public mutating func flush() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }

    static func completePrefixLength(_ bytes: [UInt8]) -> Int {
        let count = bytes.count
        var index = count - 1
        var continuationBytes = 0
        while index >= 0, continuationBytes < 3, bytes[index] & 0xC0 == 0x80 {
            index -= 1
            continuationBytes += 1
        }
        guard index >= 0 else { return count }
        let lead = bytes[index]
        let expected: Int
        switch lead {
        case 0x00...0x7F: expected = 1
        case 0xC0...0xDF: expected = 2
        case 0xE0...0xEF: expected = 3
        case 0xF0...0xF7: expected = 4
        default: return count
        }
        return index + expected > count ? index : count
    }
}
