import AppKit
import HarborCore
import SwiftUI

struct AppearancePane: View {
    @Bindable var store: SettingsStore

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)]

    var body: some View {
        Form {
            Section("Theme") {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(BuiltInThemes.all) { theme in
                        ThemeCard(theme: theme, isSelected: store.settings.appearance.themeID == theme.id)
                            .onTapGesture { store.settings.appearance.themeID = theme.id }
                    }
                }
                .padding(.vertical, 6)
                Toggle("Use a light theme when macOS is in Light mode", isOn: $store.settings.appearance.followSystemAppearance)
                if store.settings.appearance.followSystemAppearance {
                    Picker("Light theme", selection: $store.settings.appearance.lightThemeID) {
                        ForEach(BuiltInThemes.all.filter { !$0.isDark }) { Text($0.name).tag($0.id) }
                    }
                }
            }

            Section("Text") {
                Picker("Font", selection: $store.settings.appearance.fontName) {
                    Text("SF Mono (system)").tag(String?.none)
                    ForEach(MonospacedFonts.all, id: \.postScriptName) { font in
                        Text(font.displayName).tag(String?.some(font.postScriptName))
                    }
                }
                Stepper(value: $store.settings.appearance.fontSize, in: 8...36, step: 0.5) {
                    LabeledContent("Size", value: "\(store.settings.appearance.fontSize.formatted()) pt")
                }
                Toggle("Show bold text in bright colours", isOn: $store.settings.appearance.brightBoldText)
            }

            Section("Cursor") {
                Picker("Shape", selection: $store.settings.appearance.cursorShape) {
                    Text("Block").tag(CursorShape.block)
                    Text("Underline").tag(CursorShape.underline)
                    Text("Bar").tag(CursorShape.bar)
                }
                .pickerStyle(.segmented)
                Toggle("Blink", isOn: $store.settings.appearance.cursorBlinks)
            }

            Section("Window") {
                LabeledContent("Background opacity") {
                    HStack {
                        Slider(value: $store.settings.appearance.backgroundOpacity, in: 0.3...1)
                        Text("\(Int(store.settings.appearance.backgroundOpacity * 100))%")
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Blur what's behind the window", isOn: $store.settings.appearance.backgroundBlur)
                    .disabled(store.settings.appearance.backgroundOpacity >= 0.999)
                LabeledContent("Padding") {
                    Slider(value: $store.settings.appearance.contentPadding, in: 0...24, step: 1)
                }
                Footnote("The size new windows open at is under General.")
            }

            Section("Rendering") {
                Toggle("GPU rendering (Metal)", isOn: $store.settings.appearance.useMetalRenderer)
                Footnote("Metal is fastest for heavy output. Turn it off only if you see drawing problems.")
            }
        }
        .formStyle(.grouped)
    }
}

/// A miniature terminal drawn in a theme's colours.
struct ThemeCard: View {
    let theme: TerminalTheme
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("~/src").foregroundStyle(theme.ansiColor(6).color)
                    Text("main").foregroundStyle(theme.ansiColor(8).color)
                }
                HStack(spacing: 4) {
                    Text("❯").foregroundStyle(theme.ansiColor(5).color)
                    Text("ls").foregroundStyle(theme.foreground.color)
                }
                HStack(spacing: 3) {
                    ForEach(1..<7) { index in
                        RoundedRectangle(cornerRadius: 2).fill(theme.ansiColor(index).color).frame(width: 12, height: 6)
                    }
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .background(theme.background.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2.5 : 1))
            Text(theme.name).font(.caption).foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Installed fixed-pitch fonts, one per family.
enum MonospacedFonts {
    struct Font: Hashable {
        let displayName: String
        let postScriptName: String
    }

    @MainActor static let all: [Font] = NSFontManager.shared.availableFontFamilies.compactMap { family in
        guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12), font.isFixedPitch,
              !family.hasPrefix(".") else { return nil }
        return Font(displayName: family, postScriptName: font.fontName)
    }
}
