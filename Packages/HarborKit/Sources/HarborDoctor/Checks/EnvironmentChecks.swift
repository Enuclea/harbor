import Foundation
import HarborCore
import HarborShell
import HarborSSH

/// Running from a disk image or a translocated quarantine folder breaks the AI bridge path
/// and updates.
struct AppLocationCheck: DiagnosticCheck {
    let id = "app-location"
    let title = "App location"

    func run(_ context: DoctorContext) async -> CheckResult {
        let path = context.appBundlePath
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return result(.failure, "Harbor is running from a temporary location.",
                          detail: "macOS runs downloaded apps from a randomised path until they're moved. AI assistants and updates need a stable location.",
                          remedy: Remedy("Show Harbor in Finder", .revealInFinder(path: path)))
        }
        if !path.hasPrefix("/Applications/"), !path.contains("/Applications/"), path.hasSuffix(".app") {
            return result(.info, "Running from \((path as NSString).deletingLastPathComponent).",
                          detail: "Move Harbor to Applications for automatic updates.")
        }
        return result(.pass, "Installed at \(path).")
    }
}

struct LoginShellCheck: DiagnosticCheck {
    let id = "login-shell"
    let title = "Shell"

    func run(_ context: DoctorContext) async -> CheckResult {
        let shell = context.settings.shell.shellPath ?? LoginShell.path
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            return result(.failure, "\(shell) can't be run.", remedy: Remedy("Choose a shell", .openSettings(section: "terminal")))
        }
        let version = try? await ProcessRunner.run(shell, ["--version"], timeout: .seconds(5))
        let firstLine = version?.output.split(separator: "\n").first.map(String.init)
        return result(.pass, firstLine ?? shell)
    }
}

struct ShellIntegrationCheck: DiagnosticCheck {
    let id = "shell-integration"
    let title = "Shell integration"

    func run(_ context: DoctorContext) async -> CheckResult {
        guard context.settings.shell.shellIntegration else {
            return result(.info, "Turned off. Directory tracking, prompt marks and AI command results are limited.",
                          remedy: Remedy("Turn on", .openSettings(section: "terminal")))
        }
        let installer = ShellIntegrationInstaller(layout: ShellIntegrationLayout(paths: context.paths))
        guard installer.isCurrent else {
            return result(.failure, "Integration scripts are missing or out of date.",
                          remedy: Remedy("Reinstall", .reinstallShellIntegration))
        }
        let shell = ShellKind(path: context.settings.shell.shellPath ?? LoginShell.path)
        if !shell.supportsIntegration {
            return result(.warning, "Your shell isn't supported for integration; zsh, bash and fish are.")
        }
        if context.shellsReportingIntegration.contains(shell.rawValue) {
            return result(.pass, "Active in \(shell.rawValue) tabs.")
        }
        return result(.info, "Installed. It will report in when a \(shell.rawValue) tab opens.")
    }
}

/// Prompt frameworks that redraw PS1 every prompt override Harbor's prompt.
struct PromptConflictCheck: DiagnosticCheck {
    let id = "prompt-conflict"
    let title = "Prompt"

    func run(_ context: DoctorContext) async -> CheckResult {
        guard context.settings.shell.promptScope != .keepExisting else {
            return result(.pass, "Using your own prompt.")
        }
        let rc = (try? String(contentsOf: context.paths.home.appending(path: ".zshrc"), encoding: .utf8)) ?? ""
        let frameworks = [("starship init", "Starship"), ("powerlevel10k", "Powerlevel10k"), ("p10k", "Powerlevel10k"), ("oh-my-posh", "Oh My Posh")]
        if let match = frameworks.first(where: { rc.contains($0.0) }) {
            return result(.warning, "\(match.1) in ~/.zshrc may replace Harbor's prompt.",
                          detail: "Choose “Keep my prompt” to use \(match.1), or remove it from ~/.zshrc to use Harbor's.",
                          remedy: Remedy("Open Prompt settings", .openSettings(section: "prompt")))
        }
        return result(.pass, "Harbor prompt “\(context.settings.shell.prompt.presetName ?? "Custom")” — \(context.settings.shell.promptScope.label).")
    }
}

struct LogStorageCheck: DiagnosticCheck {
    let id = "log-storage"
    let title = "Logs"

    func run(_ context: DoctorContext) async -> CheckResult {
        let logs = context.paths.logs
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: logs.path) else {
            return result(.failure, "\(logs.path) isn't writable.", remedy: Remedy("Show in Finder", .revealInFinder(path: logs.path)))
        }
        let free = (try? logs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        if free > 0, free < 500_000_000 {
            return result(.warning, "Less than 500 MB free on the startup disk.")
        }
        return result(.pass, "Writing to ~/Library/Logs/\(AppIdentity.name).", remedy: Remedy("Show logs", .revealInFinder(path: logs.path)))
    }
}
