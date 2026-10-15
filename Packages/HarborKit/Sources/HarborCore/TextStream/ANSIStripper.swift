import Foundation

/// Turns raw terminal output into the plain text a person would read on screen.
///
/// Escape sequences (CSI, OSC, DCS, charset selection…) are removed, and line-local
/// cursor control is *applied* rather than dropped: carriage return moves to column 0
/// and later text overwrites, backspace moves left, and erase-in-line clears. So
/// progress bars collapse to their final state and shell redraw noise (zsh's
/// PROMPT_SP `%`) disappears. Streaming-safe: state carries across chunks.
///
/// Used for plain-text transcripts and for command output returned to assistants.
public struct ANSIStripper: Sendable {
    private enum State: Sendable {
        case text, escape, csi, osc, oscEscape, stringCommand, stringEscape, charset
    }

    private var state: State = .text
    private var csiParameters: [UInt8] = []
    private var pendingText: [UInt8] = []
    private var decoder = UTF8StreamDecoder()
    private var line = LineBuffer()

    public init() {}

    /// Returns the lines completed by `data` (each ending in `\n`). The line in progress
    /// is held until it ends or `finish()` is called.
    public mutating func strip(_ data: Data) -> String {
        var output = ""
        for byte in data {
            switch state {
            case .text:
                switch byte {
                case 0x1B:
                    flushText()
                    state = .escape
                case 0x0A:
                    flushText()
                    output += line.finishLine()
                case 0x0D:
                    flushText()
                    line.carriageReturn()
                case 0x08:
                    flushText()
                    line.backspace()
                case 0x09:
                    pendingText.append(byte)
                case 0x00...0x1F, 0x7F:
                    break
                default:
                    pendingText.append(byte)
                }
            case .escape:
                switch byte {
                case 0x5B: state = .csi                              // [
                case 0x5D: state = .osc                              // ]
                case 0x50, 0x58, 0x5E, 0x5F: state = .stringCommand  // P X ^ _
                case 0x20...0x2F: state = .charset                   // ( ) * + # take one more byte
                default: state = .text
                }
            case .csi:
                if (0x40...0x7E).contains(byte) {
                    if byte == 0x4B { line.eraseInLine(mode: Int(String(decoding: csiParameters, as: UTF8.self)) ?? 0) } // K
                    csiParameters.removeAll(keepingCapacity: true)
                    state = .text
                } else if csiParameters.count < 32 {
                    csiParameters.append(byte)
                }
            case .osc:
                if byte == 0x07 { state = .text } else if byte == 0x1B { state = .oscEscape }
            case .oscEscape:
                state = byte == 0x5C ? .text : .osc
            case .stringCommand:
                if byte == 0x1B { state = .stringEscape }
            case .stringEscape:
                state = byte == 0x5C ? .text : .stringCommand
            case .charset:
                state = .text
            }
        }
        flushText()
        return output
    }

    /// Returns the unfinished last line, if any.
    public mutating func finish() -> String {
        flushText()
        line.write(decoder.flush())
        return line.takePartial()
    }

    /// One-shot convenience for complete buffers.
    public static func plainText(from data: Data) -> String {
        var stripper = ANSIStripper()
        return stripper.strip(data) + stripper.finish()
    }

    private mutating func flushText() {
        guard !pendingText.isEmpty else { return }
        line.write(decoder.decode(Data(pendingText)))
        pendingText.removeAll(keepingCapacity: true)
    }
}

/// A single terminal line with a cursor, supporting overwrite semantics.
struct LineBuffer: Sendable {
    private var characters: [Character] = []
    private var cursor = 0

    mutating func write(_ text: String) {
        for character in text {
            if cursor < characters.count {
                characters[cursor] = character
            } else {
                if cursor > characters.count {
                    characters.append(contentsOf: repeatElement(" ", count: cursor - characters.count))
                }
                characters.append(character)
            }
            cursor += 1
        }
    }

    mutating func carriageReturn() {
        cursor = 0
    }

    mutating func backspace() {
        cursor = max(0, cursor - 1)
    }

    /// CSI K: 0 = cursor to end, 1 = start to cursor, 2 = whole line.
    mutating func eraseInLine(mode: Int) {
        switch mode {
        case 1:
            for index in 0..<min(cursor + 1, characters.count) { characters[index] = " " }
        case 2:
            characters.removeAll()
        default:
            if cursor < characters.count { characters.removeSubrange(cursor...) }
        }
    }

    mutating func finishLine() -> String {
        takePartial() + "\n"
    }

    mutating func takePartial() -> String {
        defer {
            characters.removeAll(keepingCapacity: true)
            cursor = 0
        }
        var text = String(characters)
        while text.last == " " { text.removeLast() }
        return text
    }
}
