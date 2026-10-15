import Darwin
import Foundation

/// The shells Harbor knows how to integrate with.
public enum ShellKind: String, Sendable, CaseIterable {
    case zsh, bash, fish, other

    public init(path: String) {
        let name = (path as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        self = ShellKind(rawValue: name) ?? .other
    }

    public var supportsIntegration: Bool { self != .other }

    public var promptFileExtension: String? {
        switch self {
        case .zsh: "zsh"
        case .bash: "bash"
        case .fish: "fish"
        case .other: nil
        }
    }
}

/// The user's login shell as recorded in the directory service (what Terminal.app launches).
public enum LoginShell {
    public static var path: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }

    /// Shells listed in `/etc/shells`, for the shell picker.
    public static var available: [String] {
        guard let contents = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) else { return ["/bin/zsh", "/bin/bash"] }
        return contents.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }
}
