import Foundation
import HarborCore
import HarborSSH

public enum CheckStatus: String, Sendable, Codable, Comparable {
    case pass, info, warning, failure

    private var rank: Int {
        switch self {
        case .pass: 0
        case .info: 1
        case .warning: 2
        case .failure: 3
        }
    }

    public static func < (lhs: CheckStatus, rhs: CheckStatus) -> Bool { lhs.rank < rhs.rank }
}

/// A one-click fix the UI can offer. Harbor performs it only when the user clicks.
public enum RemedyAction: Sendable, Equatable {
    /// Run a command in a visible tab, so the user sees exactly what happens.
    case runInTerminal(CommandSpec, title: String)
    case fixPermissions(path: String, mode: Int)
    case reinstallShellIntegration
    case openSettings(section: String)
    case openURL(URL)
    case revealInFinder(path: String)
}

public struct Remedy: Sendable, Equatable {
    public let title: String
    public let action: RemedyAction

    public init(_ title: String, _ action: RemedyAction) {
        self.title = title
        self.action = action
    }
}

public struct CheckResult: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let status: CheckStatus
    public let summary: String
    public let detail: String?
    public let remedy: Remedy?

    public init(id: String, title: String, status: CheckStatus, summary: String, detail: String? = nil, remedy: Remedy? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.summary = summary
        self.detail = detail
        self.remedy = remedy
    }
}

/// One open SSH tab, for the remote-integration check.
public struct SSHTabFact: Sendable, Equatable {
    public let hostName: String
    public let integrationInstalled: Bool
    public let reporting: Bool
    public let connectedSeconds: TimeInterval

    public init(hostName: String, integrationInstalled: Bool, reporting: Bool, connectedSeconds: TimeInterval) {
        self.hostName = hostName
        self.integrationInstalled = integrationInstalled
        self.reporting = reporting
        self.connectedSeconds = connectedSeconds
    }
}

/// Runtime facts the checks can't discover on their own.
public struct DoctorContext: Sendable {
    public var paths: AppPaths
    public var settings: AppSettings
    public var appBundlePath: String
    public var bridgePath: String
    public var controlSocketServing: Bool
    /// Shells that announced Harbor integration in this run (e.g. `["zsh"]`).
    public var shellsReportingIntegration: Set<String>
    /// Display names of AI apps Harbor is registered with.
    public var registeredAssistants: [String]
    public var remoteServerRunning: Bool
    public var sshTabs: [SSHTabFact]

    public init(paths: AppPaths, settings: AppSettings, appBundlePath: String, bridgePath: String, controlSocketServing: Bool,
                shellsReportingIntegration: Set<String>, registeredAssistants: [String], remoteServerRunning: Bool,
                sshTabs: [SSHTabFact] = []) {
        self.paths = paths
        self.settings = settings
        self.appBundlePath = appBundlePath
        self.bridgePath = bridgePath
        self.controlSocketServing = controlSocketServing
        self.shellsReportingIntegration = shellsReportingIntegration
        self.registeredAssistants = registeredAssistants
        self.remoteServerRunning = remoteServerRunning
        self.sshTabs = sshTabs
    }
}

/// One health check. Implementations are small, independent and side-effect free.
public protocol DiagnosticCheck: Sendable {
    var id: String { get }
    var title: String { get }
    func run(_ context: DoctorContext) async -> CheckResult
}

extension DiagnosticCheck {
    func result(_ status: CheckStatus, _ summary: String, detail: String? = nil, remedy: Remedy? = nil) -> CheckResult {
        CheckResult(id: id, title: title, status: status, summary: summary, detail: detail, remedy: remedy)
    }
}

public struct DoctorReport: Sendable {
    public let date: Date
    public let results: [CheckResult]

    public var worstStatus: CheckStatus { results.map(\.status).max() ?? .pass }
    public var problems: [CheckResult] { results.filter { $0.status >= .warning } }

    /// Markdown for support bundles and for pasting into an issue.
    public var markdown: String {
        var lines = ["# \(AppIdentity.name) diagnostics", "", "\(date.formatted(.iso8601)) · \(AppIdentity.name) \(AppIdentity.version) (\(AppIdentity.build))", ""]
        for result in results {
            let icon = switch result.status {
            case .pass: "✅"
            case .info: "ℹ️"
            case .warning: "⚠️"
            case .failure: "❌"
            }
            lines.append("- \(icon) **\(result.title)** — \(result.summary)")
            if let detail = result.detail { lines.append("  - \(detail)") }
            if let remedy = result.remedy { lines.append("  - Fix: \(remedy.title)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
