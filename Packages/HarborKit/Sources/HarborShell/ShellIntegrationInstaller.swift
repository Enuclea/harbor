import Foundation
import HarborCore
import HarborLogging

public enum ShellIntegrationError: Error, LocalizedError {
    case bundledScriptsMissing

    public var errorDescription: String? {
        "Harbor's shell-integration scripts are missing from the app bundle. Reinstall Harbor."
    }
}

/// Copies the bundled integration scripts into Application Support so shells get stable
/// paths that survive app updates and moves.
public struct ShellIntegrationInstaller: Sendable {
    public let layout: ShellIntegrationLayout
    private let log = Log(.shell)

    public init(layout: ShellIntegrationLayout) {
        self.layout = layout
    }

    /// The version currently installed, or nil if never installed.
    public var installedVersion: Int? {
        (try? String(contentsOf: layout.versionFile, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public var isCurrent: Bool { installedVersion == AppIdentity.shellIntegrationVersion }

    /// Installs (or refreshes) the scripts. Idempotent and cheap; run at every launch.
    public func install() throws {
        guard let bundled = Bundle.module.url(forResource: "integration", withExtension: nil) else {
            throw ShellIntegrationError.bundledScriptsMissing
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: layout.root, withIntermediateDirectories: true)
        let enumerator = fileManager.enumerator(at: bundled, includingPropertiesForKeys: [.isRegularFileKey])
        while let source = enumerator?.nextObject() as? URL {
            guard (try? source.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = source.path.replacingOccurrences(of: bundled.path + "/", with: "")
            // Resource bundles can't reliably carry dotfiles, so `zsh/zshenv` ships without the dot.
            let destinationPath = relative == "zsh/zshenv" ? "zsh/.zshenv" : relative
            let destination = layout.root.appending(path: destinationPath)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: source)
            if (try? Data(contentsOf: destination)) != data {
                try data.write(to: destination, options: .atomic)
            }
        }
        try "\(AppIdentity.shellIntegrationVersion)\n".write(to: layout.versionFile, atomically: true, encoding: .utf8)
        log.info("shell integration v\(AppIdentity.shellIntegrationVersion) installed at \(layout.root.path)")
    }
}
