import Foundation
import HarborCore
import HarborLogging

/// Runs every health check concurrently and collects the results in a stable order.
public struct Doctor: Sendable {
    public let checks: [any DiagnosticCheck]
    private let log = Log(.doctor)

    public init(checks: [any DiagnosticCheck] = Doctor.standardChecks) {
        self.checks = checks
    }

    public static let standardChecks: [any DiagnosticCheck] = [
        AppLocationCheck(),
        LoginShellCheck(),
        ShellIntegrationCheck(),
        PromptConflictCheck(),
        SSHDirectoryCheck(),
        SSHAgentCheck(),
        ConnectionSharingCheck(),
        AssistantBridgeCheck(),
        RemoteAccessCheck(),
        LogStorageCheck(),
    ]

    public func run(_ context: DoctorContext) async -> DoctorReport {
        let results = await withTaskGroup(of: (Int, CheckResult).self) { group in
            for (index, check) in checks.enumerated() {
                group.addTask { (index, await check.run(context)) }
            }
            var collected: [(Int, CheckResult)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let report = DoctorReport(date: Date(), results: results)
        log.info("diagnostics finished: \(report.problems.count) problem(s)", ["worst": report.worstStatus.rawValue])
        return report
    }
}
