import AppKit
import SwiftUI

/// A coloured status capsule ("Connected", "Not installed"…).
struct StatusBadge: View {
    enum Tone { case good, neutral, warning, bad }

    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch tone {
        case .good: .green
        case .neutral: .secondary
        case .warning: .orange
        case .bad: .red
        }
    }
}

/// Copies a value to the pasteboard and briefly confirms.
struct CopyButton: View {
    let value: String
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : label) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .disabled(value.isEmpty)
    }
}

/// Monospaced, selectable value text.
struct CodeText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(3)
            .truncationMode(.middle)
    }
}

/// Explanatory footnote under a form section.
struct Footnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

extension Binding {
    /// Edits an optional string as a non-optional one, mapping "" to nil.
    static func optionalString(_ source: Binding<String?>) -> Binding<String> where Value == String {
        Binding<String>(
            get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
    }
}
