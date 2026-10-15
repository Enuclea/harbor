import HarborCore
import HarborShell
import SwiftUI

struct PromptPane: View {
    @Bindable var store: SettingsStore
    let services: AppServices
    @State private var previewFailure = false

    private var config: Binding<PromptConfig> { $store.settings.shell.prompt }

    var body: some View {
        Form {
            Section {
                PromptPreviewView(config: store.settings.shell.prompt, theme: services.currentTheme, failed: previewFailure)
                Toggle("Preview after a failing command", isOn: $previewFailure)
            }

            Section("Start from a preset") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(PromptPreset.allCases) { preset in
                            PresetCard(preset: preset, theme: services.currentTheme,
                                       isSelected: store.settings.shell.prompt.presetName == preset.title)
                                .onTapGesture { store.settings.shell.prompt = preset.config }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Segments") {
                ForEach(config.segments) { $segment in
                    SegmentRow(segment: $segment) {
                        store.settings.shell.prompt.segments.removeAll { $0.id == segment.id }
                        markCustom()
                    }
                }
                .onMove { from, to in
                    store.settings.shell.prompt.segments.move(fromOffsets: from, toOffset: to)
                    markCustom()
                }
                Menu("Add Segment") {
                    ForEach(PromptSegmentKind.allCases) { kind in
                        Button(kind.label) {
                            store.settings.shell.prompt.segments.append(PromptSegment(kind, color: .cyan))
                            markCustom()
                        }
                    }
                }
            }

            Section("Input line") {
                Picker("Layout", selection: config.layout) {
                    Text("One line").tag(PromptLayout.singleLine)
                    Text("Two lines").tag(PromptLayout.twoLine)
                }
                .pickerStyle(.segmented)
                LabeledContent("Symbol") {
                    HStack {
                        TextField("Symbol", text: config.symbol).frame(width: 60)
                        ForEach(["❯", "➜", "$", "%", "λ", "→"], id: \.self) { symbol in
                            Button(symbol) { store.settings.shell.prompt.symbol = symbol }.buttonStyle(.bordered)
                        }
                    }
                }
                Picker("Separator", selection: config.separator) {
                    Text("Space").tag(" ")
                    Text("Dot ·").tag(" · ")
                    Text("Bar |").tag(" | ")
                    Text("Chevron ›").tag(" › ")
                }
                PromptColorPicker(title: "Symbol colour", selection: config.symbolColor)
                PromptColorPicker(title: "After a failure", selection: config.errorColor)
            }

            Section("Use this prompt") {
                Picker("Apply to", selection: $store.settings.shell.promptScope) {
                    ForEach(PromptScope.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Footnote(scopeExplanation)
                Button("Open a New Tab to Try It") { services.actions?.openLocalTab(in: nil) }
            }
        }
        .formStyle(.grouped)
    }

    private var scopeExplanation: String {
        switch store.settings.shell.promptScope {
        case .keepExisting: "Harbor leaves your prompt alone."
        case .harborSessions: "Applied only in Harbor tabs, by loading it after your own startup files. Nothing in your home folder changes."
        case .everywhere: "Harbor adds a clearly marked block to ~/.zshrc (and ~/.bashrc / fish conf.d if present) so other terminals match. A backup is saved first; choosing another option removes the block."
        }
    }

    private func markCustom() {
        store.settings.shell.prompt.presetName = nil
    }
}

private struct SegmentRow: View {
    @Binding var segment: PromptSegment
    let delete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Text(segment.kind.label).frame(width: 120, alignment: .leading)
            PromptColorPicker(title: "", selection: $segment.color).labelsHidden().frame(width: 150)
            Toggle("Bold", isOn: $segment.bold).toggleStyle(.checkbox)
            Spacer()
            Button(role: .destructive, action: delete) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
        }
    }
}

struct PromptColorPicker: View {
    let title: String
    @Binding var selection: PromptColor

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(PromptColor.allCases) { color in
                Label {
                    Text(color.label)
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(color.resolved(in: BuiltInThemes.harborMidnight))
                }
                .tag(color)
            }
        }
    }
}

/// Renders a prompt design the way the shell will, in the active theme.
struct PromptPreviewView: View {
    let config: PromptConfig
    let theme: TerminalTheme
    let failed: Bool

    var body: some View {
        let lines = PromptPreview.lines(for: config, lastCommandFailed: failed)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines.indices, id: \.self) { index in
                line(lines[index], isLast: index == lines.count - 1)
            }
        }
        .font(.system(size: 13, design: .monospaced))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func line(_ runs: [PromptPreviewRun], isLast: Bool) -> Text {
        var text = runs.reduce(Text("")) { partial, run in
            partial + Text(run.text).foregroundColor(run.color.resolved(in: theme)).fontWeight(run.bold ? .bold : .regular)
        }
        if isLast { text = text + Text("git status").foregroundColor(theme.foreground.color) }
        return text
    }
}

private struct PresetCard: View {
    let preset: PromptPreset
    let theme: TerminalTheme
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PromptPreviewView(config: preset.config, theme: theme, failed: false)
                .frame(width: 220)
            Text(preset.title).font(.headline)
            Text(preset.summary).font(.caption).foregroundStyle(.secondary).frame(width: 220, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}
