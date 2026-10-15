import AppKit
import HarborCore
import SwiftTerm

/// Applies appearance and behaviour settings to a terminal view.
@MainActor
enum TerminalAppearance {
    static func font(for appearance: AppearanceSettings, sizeDelta: CGFloat) -> NSFont {
        let size = max(6, min(72, CGFloat(appearance.fontSize) + sizeDelta))
        if let name = appearance.fontName, let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func apply(_ settings: AppSettings, theme: TerminalTheme, sizeDelta: CGFloat, to view: HarborTerminalView) {
        let appearance = settings.appearance
        let newFont = font(for: appearance, sizeDelta: sizeDelta)
        if view.font != newFont { view.font = newFont }

        view.installColors(theme.ansi.map(\.terminalColor))
        view.nativeForegroundColor = theme.foreground.nsColor
        view.nativeBackgroundColor = theme.background.nsColor.withAlphaComponent(CGFloat(appearance.backgroundOpacity))
        view.caretColor = theme.cursor.nsColor
        view.selectedTextBackgroundColor = theme.selection.nsColor
        view.useBrightColors = appearance.brightBoldText
        view.setCursorStyle(cursorStyle(appearance))
        view.updateColorScheme(theme.isDark ? .dark : .light)

        view.optionAsMetaKey = settings.terminal.optionAsMeta
        view.copyOnSelect = settings.terminal.copyOnSelect
        view.changeScrollback(max(100, settings.terminal.scrollbackLines))
        view.bellStyle = switch settings.terminal.bell {
        case .none: .none
        case .sound: .none // the binding plays the sound so it can also badge background tabs
        case .visual, .soundAndVisual: .visual
        }
        if view.isUsingMetalRenderer != appearance.useMetalRenderer {
            try? view.setUseMetal(appearance.useMetalRenderer)
        }
    }

    static func cursorStyle(_ appearance: AppearanceSettings) -> CursorStyle {
        switch (appearance.cursorShape, appearance.cursorBlinks) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        }
    }
}
