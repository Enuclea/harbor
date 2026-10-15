import Foundation
import HarborCore

/// Where the installed integration scripts and generated prompt files live
/// (`~/Library/Application Support/Harbor/shell`).
public struct ShellIntegrationLayout: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public init(paths: AppPaths) {
        self.init(root: paths.shellIntegration)
    }

    public var zshDirectory: URL { root.appending(path: "zsh", directoryHint: .isDirectory) }
    public var bashRCFile: URL { root.appending(path: "bash/harbor-rc.bash") }
    public var fishScript: URL { root.appending(path: "fish/harbor.fish") }
    public var versionFile: URL { root.appending(path: "VERSION") }

    public func promptFile(for shell: ShellKind) -> URL? {
        shell.promptFileExtension.map { root.appending(path: "prompt.\($0)") }
    }
}
