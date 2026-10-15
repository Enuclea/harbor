import Foundation

/// Converts key names (as an assistant would write them) into the bytes a terminal sends.
///
/// Accepts `enter`, `tab`, `escape`, `backspace`, `delete`, arrows, `home`, `end`,
/// `pageup`, `pagedown`, `space`, `f1`…`f12`, `ctrl+<key>` and `alt+<key>`.
public enum KeySequence {
    public enum ParseError: Error, LocalizedError, Equatable {
        case unknownKey(String)

        public var errorDescription: String? {
            switch self {
            case .unknownKey(let key): "Unknown key “\(key)”. Try enter, tab, escape, up, ctrl+c, alt+b or f5."
            }
        }
    }

    public static func bytes(for keys: [String]) throws -> [UInt8] {
        try keys.flatMap(bytes(for:))
    }

    public static func bytes(for key: String) throws -> [UInt8] {
        let name = key.trimmingCharacters(in: .whitespaces).lowercased()
        if let named = named[name] { return Array(named.utf8) }

        for prefix in ["ctrl+", "control+", "c-", "^"] where name.hasPrefix(prefix) && name.count > prefix.count {
            return try control(String(name.dropFirst(prefix.count)), original: key)
        }
        for prefix in ["alt+", "option+", "meta+", "m-"] where name.hasPrefix(prefix) && name.count > prefix.count {
            let rest = String(key.trimmingCharacters(in: .whitespaces).dropFirst(prefix.count))
            return [0x1B] + (try bytes(for: rest))
        }
        if key.count == 1 { return Array(key.utf8) }
        throw ParseError.unknownKey(key)
    }

    private static func control(_ rest: String, original: String) throws -> [UInt8] {
        guard rest.count == 1, let scalar = rest.unicodeScalars.first, scalar.isASCII else {
            throw ParseError.unknownKey(original)
        }
        let value = UInt8(scalar.value)
        switch value {
        case 0x61...0x7A: return [value - 0x60]          // a–z → 0x01–0x1A
        case 0x40...0x5F: return [value - 0x40]          // @ [ \ ] ^ _
        case 0x20: return [0x00]                          // ctrl+space
        case 0x3F: return [0x7F]                          // ctrl+?
        default: throw ParseError.unknownKey(original)
        }
    }

    private static let named: [String: String] = [
        "enter": "\r", "return": "\r", "tab": "\t", "escape": "\u{1B}", "esc": "\u{1B}",
        "backspace": "\u{7F}", "delete": "\u{1B}[3~", "space": " ",
        "up": "\u{1B}[A", "down": "\u{1B}[B", "right": "\u{1B}[C", "left": "\u{1B}[D",
        "home": "\u{1B}[H", "end": "\u{1B}[F", "pageup": "\u{1B}[5~", "pagedown": "\u{1B}[6~",
        "insert": "\u{1B}[2~", "shift+tab": "\u{1B}[Z",
        "f1": "\u{1B}OP", "f2": "\u{1B}OQ", "f3": "\u{1B}OR", "f4": "\u{1B}OS",
        "f5": "\u{1B}[15~", "f6": "\u{1B}[17~", "f7": "\u{1B}[18~", "f8": "\u{1B}[19~",
        "f9": "\u{1B}[20~", "f10": "\u{1B}[21~", "f11": "\u{1B}[23~", "f12": "\u{1B}[24~",
    ]
}
