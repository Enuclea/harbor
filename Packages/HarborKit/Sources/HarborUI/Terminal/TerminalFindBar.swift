import AppKit
import Observation
import SwiftTerm
import SwiftUI

/// State and buffer search logic for the per-tab Find bar (`⌘F`, `⌘G`, `⇧⌘G`, `⌘E`).
@MainActor
@Observable
public final class TerminalFindModel {
    public struct Match: Equatable, Sendable {
        public let row: Int
        public let snippet: String

        public init(row: Int, snippet: String) {
            self.row = row
            self.snippet = snippet
        }
    }

    public var isVisible = false
    public var query = "" {
        didSet { if oldValue != query { recomputeMatches() } }
    }
    public var caseSensitive = false {
        didSet { if oldValue != caseSensitive { recomputeMatches() } }
    }
    public var useRegex = false {
        didSet { if oldValue != useRegex { recomputeMatches() } }
    }
    public private(set) var matches: [Match] = []
    public private(set) var currentIndex: Int = 0

    @ObservationIgnored weak var terminal: TerminalView?
    @ObservationIgnored var onDismiss: @MainActor () -> Void = {}

    public init(terminal: TerminalView? = nil) {
        self.terminal = terminal
    }

    public var statusLabel: String {
        guard !query.isEmpty else { return "" }
        guard !matches.isEmpty else { return "0 matches" }
        return "\(currentIndex + 1) of \(matches.count)"
    }

    public func search(in lines: [String]) {
        guard !query.isEmpty else {
            matches = []
            currentIndex = 0
            return
        }
        var found: [Match] = []
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var regex: NSRegularExpression?
        if useRegex {
            let regexOpts: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            regex = try? NSRegularExpression(pattern: query, options: regexOpts)
            if regex == nil {
                matches = []
                currentIndex = 0
                return
            }
        }

        for (row, line) in lines.enumerated() {
            let matched: Bool
            if let regex {
                let range = NSRange(line.startIndex..., in: line)
                matched = regex.firstMatch(in: line, range: range) != nil
            } else {
                matched = line.range(of: query, options: options) != nil
            }
            if matched {
                found.append(Match(row: row, snippet: line))
            }
        }
        matches = found
        currentIndex = found.isEmpty ? 0 : found.count - 1
    }

    public func recomputeMatches() {
        guard let terminal else { return }
        let buffer = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
        var lines = buffer.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        search(in: lines)
        scrollToCurrent()
    }

    public func findNext() {
        if matches.isEmpty { recomputeMatches() }
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + 1) % matches.count
        scrollToCurrent()
    }

    public func findPrevious() {
        if matches.isEmpty { recomputeMatches() }
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex - 1 + matches.count) % matches.count
        scrollToCurrent()
    }

    public func useSelection() {
        guard let selection = terminal?.getSelection()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selection.isEmpty else { return }
        query = selection
        if !isVisible { isVisible = true }
        recomputeMatches()
    }

    private func scrollToCurrent() {
        guard matches.indices.contains(currentIndex) else { return }
        terminal?.scrollTo(row: matches[currentIndex].row)
    }
}

/// Compact floating search bar anchored at the top-right of a terminal tab.
struct TerminalFindBar: View {
    @Bindable var model: TerminalFindModel
    @FocusState private var focused: Bool

    var body: some View {
        if model.isVisible {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                TextField("Find in terminal…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .frame(width: 180)
                    .focused($focused)
                    .onSubmit { model.findNext() }

                if !model.statusLabel.isEmpty {
                    Text(model.statusLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(model.matches.isEmpty ? .orange : .secondary)
                        .fixedSize()
                }

                Divider().frame(height: 14)

                Button {
                    model.caseSensitive.toggle()
                } label: {
                    Text("Aa")
                        .font(.caption.weight(model.caseSensitive ? .bold : .regular))
                        .foregroundStyle(model.caseSensitive ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Match Case")

                Button {
                    model.useRegex.toggle()
                } label: {
                    Text(".*")
                        .font(.caption.monospaced().weight(model.useRegex ? .bold : .regular))
                        .foregroundStyle(model.useRegex ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Regular Expression")

                Button { model.findPrevious() } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(model.matches.isEmpty)
                    .help("Previous Match (⇧⌘G)")

                Button { model.findNext() } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(model.matches.isEmpty)
                    .help("Next Match (⌘G)")

                Button {
                    model.isVisible = false
                    model.onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close Find Bar (Esc)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassPanel(cornerRadius: 11)
            .onAppear {
                focused = true
                model.recomputeMatches()
            }
            .onKeyPress(.escape) {
                model.isVisible = false
                model.onDismiss()
                return .handled
            }
        }
    }
}
