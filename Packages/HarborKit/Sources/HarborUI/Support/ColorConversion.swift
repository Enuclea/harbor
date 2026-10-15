import AppKit
import HarborCore
import SwiftTerm
import SwiftUI

extension HarborCore.RGBColor {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    var color: SwiftUI.Color { SwiftUI.Color(nsColor: nsColor) }

    var terminalColor: SwiftTerm.Color {
        SwiftTerm.Color(red8: UInt16(red), green8: UInt16(green), blue8: UInt16(blue))
    }
}

extension HostColor {
    /// System colours adapt to light/dark and to the accessibility "increase contrast" setting.
    var nsColor: NSColor? {
        switch self {
        case .none: nil
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .teal: .systemTeal
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .gray: .systemGray
        }
    }

    var color: SwiftUI.Color? { nsColor.map(SwiftUI.Color.init(nsColor:)) }
}

extension PromptColor {
    /// Resolves a prompt colour against a theme so previews match the shell.
    func resolved(in theme: TerminalTheme) -> SwiftUI.Color {
        guard let index = ansiIndex else { return theme.foreground.color }
        return theme.ansiColor(index).color
    }
}
