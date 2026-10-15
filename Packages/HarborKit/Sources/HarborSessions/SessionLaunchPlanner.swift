import Foundation
import HarborCore
import HarborPTY
import HarborShell
import HarborSSH

/// Turns a `SessionKind` plus settings into an exact process configuration.
public struct SessionLaunchPlanner: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func configuration(
        for kind: SessionKind,
        settings: AppSettings,
        workingDirectory: String?,
        size: TerminalSize,
        sessionID: SessionID,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> PTYProcess.Configuration {
        var environment = baseEnvironment(settings: settings, sessionID: sessionID, inherited: inheritedEnvironment)
        switch kind {
        case .localShell:
            let shell = settings.shell.shellPath.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? LoginShell.path
            let plan = ShellLaunchPlanner(layout: ShellIntegrationLayout(paths: paths)).plan(
                shellPath: shell,
                loginShell: settings.shell.launchAsLoginShell,
                integration: settings.shell.shellIntegration,
                promptScope: settings.shell.promptScope,
                inheritedEnvironment: inheritedEnvironment)
            environment["SHELL"] = shell
            environment.merge(plan.environment) { $1 }
            return PTYProcess.Configuration(
                executable: plan.executable, argv0: plan.argv0, arguments: plan.arguments,
                environment: environment, workingDirectory: directory(workingDirectory), size: size)

        case .ssh(let host):
            try HostProfileValidator.validate(host)
            let command = SSHCommandBuilder(settings: settings.ssh, controlDirectory: paths.sshControl).interactive(host)
            return PTYProcess.Configuration(
                executable: command.executable, arguments: command.arguments,
                environment: environment, workingDirectory: paths.home.path, size: size)

        case .command(let command, _):
            return PTYProcess.Configuration(
                executable: command.executable, arguments: command.arguments,
                environment: environment, workingDirectory: directory(workingDirectory), size: size)
        }
    }

    /// Variables every session gets. Launch-context noise (Xcode, launchd, the app
    /// bundle) is removed so shells look the same as in Terminal.app.
    func baseEnvironment(settings: AppSettings, sessionID: SessionID, inherited: [String: String]) -> [String: String] {
        var environment = inherited.filter { key, _ in
            !Self.strippedKeys.contains(key) && !Self.strippedPrefixes.contains { key.hasPrefix($0) }
        }
        environment["TERM"] = settings.terminal.termType
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = AppIdentity.name
        environment["TERM_PROGRAM_VERSION"] = AppIdentity.version
        environment["LC_TERMINAL"] = AppIdentity.name
        environment["HARBOR_SESSION_ID"] = sessionID.description
        if environment["LANG"] == nil { environment["LANG"] = Self.defaultLanguage }
        if environment["PATH"] == nil { environment["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" }
        if environment["HOME"] == nil { environment["HOME"] = paths.home.path }
        if environment["USER"] == nil { environment["USER"] = NSUserName() }
        environment.merge(settings.shell.extraEnvironment) { $1 }
        return environment
    }

    private func directory(_ requested: String?) -> String {
        var isDirectory: ObjCBool = false
        if let requested, FileManager.default.fileExists(atPath: requested, isDirectory: &isDirectory), isDirectory.boolValue {
            return requested
        }
        return paths.home.path
    }

    static let strippedKeys: Set<String> = [
        "TERM_SESSION_ID", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "ITERM_SESSION_ID", "ITERM_PROFILE",
        "__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "CFProcessPath", "OS_ACTIVITY_DT_MODE",
        "NSZombieEnabled", "MallocNanoZone", "HARBOR_SESSION_ID", "HARBOR_PROMPT_FILE",
        "HARBOR_SHELL_INTEGRATION_DIR", "HARBOR_ORIG_ZDOTDIR",
    ]

    static let strippedPrefixes = ["DYLD_", "__XCODE", "__XPC_", "XCODE_", "SWIFT_DEBUG"]

    static var defaultLanguage: String {
        let locale = Locale.current
        if let language = locale.language.languageCode?.identifier, let region = locale.region?.identifier {
            return "\(language)_\(region).UTF-8"
        }
        return "en_US.UTF-8"
    }
}
