import Foundation

/// Every on-disk location Harbor uses, computed in one place.
public struct AppPaths: Sendable {
    /// `~/Library/Application Support/Harbor`
    public let applicationSupport: URL
    /// `~/Library/Logs/Harbor`
    public let logs: URL
    /// `~/.ssh/harbor` — short on purpose: Unix socket paths are limited to 104 bytes on macOS
    /// and ssh appends a 17-character temporary suffix while creating a ControlMaster socket.
    public let sshControl: URL
    /// The user's home directory.
    public let home: URL

    public init(applicationSupport: URL, logs: URL, sshControl: URL, home: URL) {
        self.applicationSupport = applicationSupport
        self.logs = logs
        self.sshControl = sshControl
        self.home = home
    }

    public static let standard: AppPaths = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        return AppPaths(
            applicationSupport: library.appending(path: "Application Support/\(AppIdentity.name)", directoryHint: .isDirectory),
            logs: library.appending(path: "Logs/\(AppIdentity.name)", directoryHint: .isDirectory),
            sshControl: home.appending(path: ".ssh/harbor", directoryHint: .isDirectory),
            home: home
        )
    }()

    public var settingsFile: URL { applicationSupport.appending(path: "settings.json") }
    public var hostsFile: URL { applicationSupport.appending(path: "hosts.json") }
    public var sessionStateFile: URL { applicationSupport.appending(path: "session-state.json") }
    public var shellIntegration: URL { applicationSupport.appending(path: "shell", directoryHint: .isDirectory) }
    public var runtime: URL { applicationSupport.appending(path: "run", directoryHint: .isDirectory) }
    public var controlSocket: URL { runtime.appending(path: "control.sock") }
    public var sessionRecordings: URL { logs.appending(path: "Sessions", directoryHint: .isDirectory) }
    public var auditLog: URL { logs.appending(path: "audit.jsonl") }
    public var sshDirectory: URL { home.appending(path: ".ssh", directoryHint: .isDirectory) }
    public var sshConfig: URL { sshDirectory.appending(path: "config") }

    /// Creates every directory Harbor writes to. Private directories get `0700`.
    public func ensureDirectories(fileManager: FileManager = .default) throws {
        for directory in [applicationSupport, logs, sessionRecordings, shellIntegration] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for privateDirectory in [runtime, sshDirectory, sshControl] {
            try fileManager.createDirectory(at: privateDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateDirectory.path)
        }
    }
}
