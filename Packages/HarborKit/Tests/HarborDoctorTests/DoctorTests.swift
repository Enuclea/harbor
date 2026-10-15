import Foundation
import HarborCore
@testable import HarborDoctor
import Testing

@Suite("Failure advisor")
struct FailureAdvisorTests {
    let host = HostProfile(name: "web", hostname: "web.example.com", port: 2222)

    @Test func recognisesChangedHostKeysAndOffersCarefulFix() throws {
        let output = """
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
            Host key verification failed.
            """
        let findings = FailureAdvisor.diagnose(output: output, host: host)
        let first = try #require(findings.first)
        #expect(first.title == "The server's identity changed")
        #expect(first.explanation.contains("intercepting"))
        guard case .runInTerminal(let command, _) = first.remedy?.action else {
            Issue.record("expected a terminal remedy")
            return
        }
        #expect(command.arguments == ["-R", "[web.example.com]:2222"])
    }

    @Test(arguments: [
        ("deploy@web: Permission denied (publickey).", "No key was accepted"),
        ("ssh: Could not resolve hostname nope: nodename nor servname provided", "The host name couldn't be found"),
        ("ssh: connect to host web port 22: Connection refused", "Nothing is accepting SSH connections"),
        ("ssh: connect to host web port 22: Operation timed out", "The server didn't answer"),
        ("Received disconnect: Too many authentication failures", "Too many keys were offered"),
    ])
    func recognisesCommonFailures(output: String, title: String) {
        #expect(FailureAdvisor.diagnose(output: output, host: host).map(\.title).contains(title))
    }

    @Test func offersDiagnosisOnlyForQuickSSHFailures() {
        #expect(FailureAdvisor.shouldOfferDiagnosis(kind: true, exitCode: 255, lifetime: 3))
        #expect(!FailureAdvisor.shouldOfferDiagnosis(kind: true, exitCode: 0, lifetime: 3))
        #expect(!FailureAdvisor.shouldOfferDiagnosis(kind: false, exitCode: 255, lifetime: 3))
        #expect(!FailureAdvisor.shouldOfferDiagnosis(kind: true, exitCode: 255, lifetime: 3_600))
    }

    @Test func probesReachability() async {
        #expect(!(await FailureAdvisor.probeReachability(host: "127.0.0.1", port: 1, timeout: .seconds(2))))
    }
}

@Suite("Doctor")
struct DoctorTests {
    @Test func flagsLoosePrivateKeyPermissions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "harbor-doctor-\(UUID())")
        let home = root.appending(path: "home")
        let paths = AppPaths(applicationSupport: root.appending(path: "support"), logs: root.appending(path: "logs"),
                             sshControl: root.appending(path: "cm"), home: home)
        try FileManager.default.createDirectory(at: paths.sshDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.sshDirectory.path)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = paths.sshDirectory.appending(path: "id_ed25519")
        try Data("-----BEGIN OPENSSH PRIVATE KEY-----".utf8).write(to: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key.path)

        let context = DoctorContext(paths: paths, settings: AppSettings(), appBundlePath: "/Applications/Harbor.app",
                                    bridgePath: "/bin/sh", controlSocketServing: true, shellsReportingIntegration: [],
                                    registeredAssistants: [], remoteServerRunning: false)
        let report = await Doctor().run(context)
        let ssh = try #require(report.results.first { $0.id == "ssh-permissions" })
        #expect(ssh.status == .failure)
        #expect(ssh.remedy?.action == .fixPermissions(path: key.path, mode: 0o600))
        #expect(report.results.map(\.id) == Doctor.standardChecks.map(\.id), "results keep a stable order")
        #expect(report.markdown.contains("SSH folder permissions"))
    }

    @Test func detectsTranslocatedApp() async {
        let paths = AppPaths.standard
        let context = DoctorContext(paths: paths, settings: AppSettings(),
                                    appBundlePath: "/private/var/folders/xy/T/AppTranslocation/ABC/d/Harbor.app",
                                    bridgePath: "/bin/sh", controlSocketServing: true, shellsReportingIntegration: [],
                                    registeredAssistants: [], remoteServerRunning: false)
        let result = await AppLocationCheck().run(context)
        #expect(result.status == .failure)
    }
}
