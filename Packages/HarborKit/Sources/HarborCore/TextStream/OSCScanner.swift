import Foundation

/// An Operating System Command found in terminal output, e.g. `ESC ] 7 ; file://host/path BEL`.
public struct OSCEvent: Sendable, Equatable {
    public let code: Int
    /// Everything after the first `;`, decoded as UTF-8.
    public let payload: String

    public init(code: Int, payload: String) {
        self.code = code
        self.payload = payload
    }
}

/// Incrementally extracts OSC sequences from a raw PTY byte stream.
///
/// Sessions use this — independently of the renderer — to learn the working directory
/// (OSC 7), titles (OSC 0/2), command boundaries and exit codes (OSC 133) and whether
/// Harbor's shell integration is active (OSC 1337). Sequences may span read boundaries.
public struct OSCScanner: Sendable {
    private enum State: Sendable { case ground, escape, payload, payloadEscape }

    private var state: State = .ground
    private var buffer: [UInt8] = []
    /// Longer sequences (e.g. inline images) are not interesting here and are dropped.
    private let maximumPayload = 8 * 1024

    public init() {}

    public mutating func scan(_ data: Data) -> [OSCEvent] {
        data.withUnsafeBytes { raw in scan(raw.bindMemory(to: UInt8.self)) }
    }

    public mutating func scan(_ bytes: UnsafeBufferPointer<UInt8>) -> [OSCEvent] {
        // Fast path: nothing pending and no ESC in this chunk.
        if state == .ground, let base = bytes.baseAddress, memchr(base, 0x1B, bytes.count) == nil {
            return []
        }
        var events: [OSCEvent] = []
        for byte in bytes {
            switch state {
            case .ground:
                if byte == 0x1B { state = .escape }
            case .escape:
                if byte == 0x5D { // ]
                    state = .payload
                    buffer.removeAll(keepingCapacity: true)
                } else if byte != 0x1B {
                    state = .ground
                }
            case .payload:
                switch byte {
                case 0x07:
                    if let event = finish() { events.append(event) }
                case 0x1B:
                    state = .payloadEscape
                case 0x18, 0x1A: // CAN / SUB abort the sequence
                    state = .ground
                default:
                    if buffer.count < maximumPayload {
                        buffer.append(byte)
                    } else {
                        state = .ground
                    }
                }
            case .payloadEscape:
                if byte == 0x5C { // ESC \ (ST)
                    if let event = finish() { events.append(event) }
                } else {
                    state = byte == 0x5D ? .payload : .ground
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
        return events
    }

    private mutating func finish() -> OSCEvent? {
        state = .ground
        let separator = buffer.firstIndex(of: 0x3B) ?? buffer.endIndex // ;
        guard let code = Int(String(decoding: buffer[..<separator], as: UTF8.self)) else { return nil }
        let payloadStart = separator < buffer.endIndex ? buffer.index(after: separator) : separator
        return OSCEvent(code: code, payload: String(decoding: buffer[payloadStart...], as: UTF8.self))
    }
}
