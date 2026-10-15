import Foundation
import HarborCore

/// How to start a shell: what to exec and which variables to add.
public struct ShellLaunchPlan: Sendable, Equatable {
    public var executable: String
    public var argv0: String
    public var arguments: [String]
    /// Variables to add on top of the session's base environment.
    public var environment: [String: String]
}

/// Decides how a local shell is launched so Harbor's integration loads *without editing
/// dotfiles*: zsh via `ZDOTDIR`, bash via `--rcfile`, fish via `--init-command`.
public struct ShellLaunchPlanner: Sendable {
    public let layout: ShellIntegrationLayout

    public init(layout: ShellIntegrationLayout) {
        self.layout = layout
    }

    public func plan(
        shellPath: String,
        loginShell: Bool,
        integration: Bool,
        promptScope: PromptScope,
        inheritedEnvironment: [String: String]
    ) -> ShellLaunchPlan {
        let kind = ShellKind(path: shellPath)
        let name = (shellPath as NSString).lastPathComponent
        var plan = ShellLaunchPlan(
            executable: shellPath,
            argv0: loginShell ? "-\(name)" : name,
            arguments: [],
            environment: [:])

        guard integration, kind.supportsIntegration else { return plan }

        plan.environment["HARBOR_SHELL_INTEGRATION_DIR"] = layout.root.path
        if promptScope == .harborSessions, let promptFile = layout.promptFile(for: kind) {
            plan.environment["HARBOR_PROMPT_FILE"] = promptFile.path
        }

        switch kind {
        case .zsh:
            if let userZDOTDIR = inheritedEnvironment["ZDOTDIR"] {
                plan.environment["HARBOR_ORIG_ZDOTDIR"] = userZDOTDIR
            }
            plan.environment["ZDOTDIR"] = layout.zshDirectory.path
        case .bash:
            // Login bash ignores --rcfile, so start it non-login and let the rc file
            // replay the login sequence.
            plan.argv0 = name
            plan.arguments = ["--rcfile", layout.bashRCFile.path]
            if loginShell { plan.environment["HARBOR_BASH_LOGIN"] = "1" }
        case .fish:
            plan.arguments = ["--init-command", "source \(Self.fishQuoted(layout.fishScript.path))"]
        case .other:
            break
        }
        return plan
    }

    static func fishQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}
