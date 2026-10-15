import Foundation

/// An sRGB colour stored as hex so theme files stay readable.
public struct RGBColor: Hashable, Sendable, Codable, CustomStringConvertible {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Accepts `#RRGGBB` or `RRGGBB`. Invalid input yields magenta so mistakes are obvious.
    public init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self.init(red: 255, green: 0, blue: 255)
            return
        }
        self.init(red: UInt8((value >> 16) & 0xFF), green: UInt8((value >> 8) & 0xFF), blue: UInt8(value & 0xFF))
    }

    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    public var description: String { hex }

    /// Relative luminance (WCAG), used to pick legible overlay colours.
    public var luminance: Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    public init(from decoder: Decoder) throws {
        self.init(hex: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// A terminal colour scheme: default colours plus the 16-colour ANSI palette.
public struct TerminalTheme: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var foreground: RGBColor
    public var background: RGBColor
    public var cursor: RGBColor
    public var selection: RGBColor
    /// Exactly 16 entries: black, red, green, yellow, blue, magenta, cyan, white, then the bright variants.
    public var ansi: [RGBColor]

    public init(id: String, name: String, foreground: String, background: String, cursor: String, selection: String, ansi: [String]) {
        precondition(ansi.count == 16, "A theme needs 16 ANSI colours")
        self.id = id
        self.name = name
        self.foreground = RGBColor(hex: foreground)
        self.background = RGBColor(hex: background)
        self.cursor = RGBColor(hex: cursor)
        self.selection = RGBColor(hex: selection)
        self.ansi = ansi.map(RGBColor.init(hex:))
    }

    public var isDark: Bool { background.luminance < 0.4 }

    public func ansiColor(_ index: Int) -> RGBColor {
        ansi.indices.contains(index) ? ansi[index] : foreground
    }
}
