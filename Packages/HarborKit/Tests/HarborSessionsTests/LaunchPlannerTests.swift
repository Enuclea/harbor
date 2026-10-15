import Foundation
import HarborCore
@testable import HarborSessions
import Testing

@Suite("Session launch planning")
struct LaunchPlannerTests {
    let planner = SessionLaunchPlanner(paths: AppPaths(
        applicationSupport: URL(fileURLWithPath: "/tmp/harbor-test/support"), logs: URL(fileURLWithPath: "/tmp/harbor-test/logs"),
        sshControl: URL(fileURLWithPath: "/tmp/harbor-test/cm"), home: URL(fileURLWithPath: "/tmp")))

    private func environment(for host: HostProfile) throws -> [String: String] {
        try planner.configuration(for: .ssh(host), settings: AppSettings(), workingDirectory: nil,
                                  size: TerminalSize(columns: 80, rows: 24), sessionID: SessionID(),
                                  inheritedEnvironment: [AppIdentity.hostNameVariable: "stale", "HARBOR_HOST_NAME": "stale"]).environment
    }

    @Test func sshTabsCarryTheHostsDisplayNameOnlyWhenAsked() throws {
        var host = HostProfile(name: "Nexus TX", hostname: "10.0.0.5")
        let plain = try environment(for: host)
        #expect(plain[AppIdentity.hostNameVariable] == nil, "a name inherited from elsewhere never leaks into a tab")
        #expect(plain["HARBOR_HOST_NAME"] == nil)
        #expect(plain["LC_TERMINAL"] == AppIdentity.name)

        host.showsNameInPrompt = true
        #expect(try environment(for: host)[AppIdentity.hostNameVariable] == "Nexus TX")
    }
}
