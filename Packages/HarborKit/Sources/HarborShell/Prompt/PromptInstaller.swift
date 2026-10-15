import Foundation
import HarborCore
import HarborLogging

/// Writes generated prompt files and, for the "Everywhere" scope, a managed block in the
/// user's rc files. Every dotfile is backed up once before Harbor first edits it.
public struct PromptInstaller: Sendable {
    public let layout: ShellIntegrationLayout
    public let home: URL
    private let log = Log(.shell)

    static let blockName = "harbor prompt"

    public init(layout: ShellIntegrationLayout, home: URL) {
        self.layout = layout
        self.home = home
    }

    /// Regenerates `prompt.zsh`, `prompt.bash` and `prompt.fish`.
    public func writePromptFiles(_ config: PromptConfig) throws {
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        for shell in [ShellKind.zsh, .bash, .fish] {
            guard let url = layout.promptFile(for: shell), let script = PromptBuilder.render(config, for: shell) else { continue }
            try script.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Applies `scope`, returning the dotfiles that were changed.
    @discardableResult
    public func apply(scope: PromptScope, config: PromptConfig) throws -> [URL] {
        try writePromptFiles(config)
        let changed: [URL]
        switch scope {
        case .everywhere: changed = try installManagedBlocks()
        case .harborSessions, .keepExisting: changed = try removeManagedBlocks()
        }
        if !changed.isEmpty {
            log.notice("prompt scope \(scope.rawValue) updated \(changed.map(\.lastPathComponent).joined(separator: ", "))")
        }
        return changed
    }

    // MARK: Dotfiles

    private var rcTargets: [(file: URL, shell: ShellKind, createIfMissing: Bool)] {
        [
            (home.appending(path: ".zshrc"), .zsh, true),
            (home.appending(path: ".bashrc"), .bash, false),
            (home.appending(path: ".bash_profile"), .bash, false),
        ]
    }

    private var fishConfD: URL { home.appending(path: ".config/fish/conf.d/harbor-prompt.fish") }

    private func installManagedBlocks() throws -> [URL] {
        var changed: [URL] = []
        for target in rcTargets {
            let exists = FileManager.default.fileExists(atPath: target.file.path)
            guard exists || target.createIfMissing, let prompt = layout.promptFile(for: target.shell) else { continue }
            let original = exists ? try String(contentsOf: target.file, encoding: .utf8) : ""
            let body = """
                # Added by \(AppIdentity.name). Remove this block, or choose “Keep my prompt” in \(AppIdentity.name), to undo.
                [ -r "\(prompt.path)" ] && source "\(prompt.path)"
                """
            let updated = ManagedBlock.upsert(name: Self.blockName, body: body, in: original)
            if updated != original {
                try backupOnce(target.file)
                try updated.write(to: target.file, atomically: true, encoding: .utf8)
                changed.append(target.file)
            }
        }
        if FileManager.default.fileExists(atPath: home.appending(path: ".config/fish").path),
           let prompt = layout.promptFile(for: .fish) {
            try FileManager.default.createDirectory(at: fishConfD.deletingLastPathComponent(), withIntermediateDirectories: true)
            let script = "# Added by \(AppIdentity.name).\ntest -r '\(prompt.path)'; and source '\(prompt.path)'\n"
            if (try? String(contentsOf: fishConfD, encoding: .utf8)) != script {
                try script.write(to: fishConfD, atomically: true, encoding: .utf8)
                changed.append(fishConfD)
            }
        }
        return changed
    }

    private func removeManagedBlocks() throws -> [URL] {
        var changed: [URL] = []
        for target in rcTargets where FileManager.default.fileExists(atPath: target.file.path) {
            let original = try String(contentsOf: target.file, encoding: .utf8)
            let updated = ManagedBlock.remove(name: Self.blockName, from: original)
            if updated != original {
                try updated.write(to: target.file, atomically: true, encoding: .utf8)
                changed.append(target.file)
            }
        }
        if FileManager.default.fileExists(atPath: fishConfD.path) {
            try FileManager.default.removeItem(at: fishConfD)
            changed.append(fishConfD)
        }
        return changed
    }

    private func backupOnce(_ file: URL) throws {
        let backup = file.deletingLastPathComponent().appending(path: file.lastPathComponent + ".harbor-backup")
        guard FileManager.default.fileExists(atPath: file.path),
              !FileManager.default.fileExists(atPath: backup.path) else { return }
        try FileManager.default.copyItem(at: file, to: backup)
    }
}

/// Edits a `# >>> name >>>` … `# <<< name <<<` block inside a text file, leaving
/// everything outside the markers untouched.
public enum ManagedBlock {
    public static func upsert(name: String, body: String, in text: String) -> String {
        let block = "\(startMarker(name))\n\(body)\n\(endMarker(name))\n"
        if let range = blockRange(name: name, in: text) {
            return text.replacingCharacters(in: range, with: block)
        }
        let separator = text.isEmpty || text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
        return text + separator + block
    }

    public static func remove(name: String, from text: String) -> String {
        guard let range = blockRange(name: name, in: text) else { return text }
        var result = text
        result.removeSubrange(range)
        while result.hasSuffix("\n\n\n") { result.removeLast() }
        return result
    }

    static func blockRange(name: String, in text: String) -> Range<String.Index>? {
        guard let start = text.range(of: startMarker(name)),
              let end = text.range(of: endMarker(name), range: start.upperBound..<text.endIndex) else { return nil }
        var upper = end.upperBound
        if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        return start.lowerBound..<upper
    }

    private static func startMarker(_ name: String) -> String { "# >>> \(name) >>>" }
    private static func endMarker(_ name: String) -> String { "# <<< \(name) <<<" }
}
