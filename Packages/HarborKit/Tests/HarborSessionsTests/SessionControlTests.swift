import Foundation
import HarborControl
import HarborCore
import HarborLogging
@testable import HarborSessions
import HarborShell
import HarborSSH
import Testing

/// A complete, isolated Harbor environment around a real zsh — no UI, no dotfiles.
@MainActor
private final class Harness {
    let root: URL
    let paths: AppPaths
    let settings: SettingsStore
    let hosts: HostLibrary
    let manager: SessionManager
    let control: SessionControlService

    init(configure: (inout AppSettings) -> Void = { _ in }) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "harbor-sessions-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        paths = AppPaths(
            applicationSupport: root.appending(path: "support"), logs: root.appending(path: "logs"),
            sshControl: root.appending(path: "cm"), home: home)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try paths.ensureDirectories()
        let layout = ShellIntegrationLayout(paths: paths)
        try ShellIntegrationInstaller(layout: layout).install()
        try PromptInstaller(layout: layout, home: home).writePromptFiles(PromptPreset.minimal.config)

        settings = SettingsStore(store: JSONFileStore(url: paths.settingsFile) { AppSettings() })
        settings.update {
            $0.shell.shellPath = "/bin/zsh"
            $0.shell.launchAsLoginShell = false
            $0.terminal.exitBehavior = .keepOpen
            configure(&$0)
        }
        hosts = HostLibrary(store: JSONFileStore(url: paths.hostsFile) { HostDocument() })
        manager = SessionManager(
            settings: settings, hosts: hosts, paths: paths,
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"])
        control = SessionControlService(manager: manager, hosts: hosts, settings: settings, audit: AuditTrail(url: paths.auditLog))
    }

    /// Opens a shell and waits until zsh has announced integration and drawn a prompt.
    func openReadyShell() async throws -> TerminalSession {
        let session = manager.open(.localShell)
        let deadline = ContinuousClock.now + .seconds(10)
        while !(session.shellIntegration == "zsh" && session.isAtPrompt) {
            guard ContinuousClock.now < deadline else {
                Issue.record("shell never became ready; state=\(session.state)")
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return session
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private let assistant = ControlClient(kind: .assistant, name: "test-assistant")

@Suite("Session control (live zsh)", .serialized)
@MainActor
struct SessionControlTests {
    @Test func runCommandReturnsOutputAndExitCode() async throws {
        let harness = try Harness { $0.ai.inputPolicy = .allow }
        let session = try await harness.openReadyShell()

        let ok = try await harness.control.runCommand("1", command: "echo hello-from-harbor", timeout: .seconds(10), client: assistant)
        #expect(ok.completed)
        #expect(ok.exitCode == 0)
        #expect(ok.output == "hello-from-harbor")

        let failing = try await harness.control.runCommand("current", command: "ls /definitely-missing", timeout: .seconds(10), client: assistant)
        #expect(failing.completed)
        #expect(failing.exitCode != 0)
        #expect(failing.output.contains("No such file"))

        #expect(session.lastCommand?.exitCode == failing.exitCode)
        harness.manager.close(session)
    }

    @Test func activityTracksRunningCommands() async throws {
        let harness = try Harness { $0.ai.inputPolicy = .allow }
        let session = try await harness.openReadyShell()
        #expect(session.activity == .idle(lastExitCode: nil))
        #expect(session.shellIntegrationVersion == AppIdentity.shellIntegrationVersion)

        try await harness.control.sendInput("1", text: "sleep 1\r", client: assistant)
        let deadline = ContinuousClock.now + .seconds(5)
        while case .idle = session.activity, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        guard case .busy(let since, let command) = session.activity else {
            Issue.record("expected busy, got \(session.activity)")
            return
        }
        #expect(since != nil)
        #expect(command == "sleep 1")
        #expect(try await harness.control.describeSession("1").activity == "busy")
        #expect(try await harness.control.describeSession("1").runningCommand == "sleep 1")

        while case .busy = session.activity, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(session.activity == .idle(lastExitCode: 0))
        #expect(session.runningCommand == nil)
        #expect(session.lastCommandLine == "sleep 1", "the last command stays visible after it finishes")
        #expect(session.lastCommandFromAssistant)
        harness.manager.close(session)
    }

    @Test func listsAndDescribesTabs() async throws {
        let harness = try Harness()
        let session = try await harness.openReadyShell()
        let tabs = await harness.control.listSessions()
        #expect(tabs.count == 1)
        #expect(tabs[0].index == 1)
        #expect(tabs[0].kind == "local")
        #expect(tabs[0].shellIntegration == "zsh")
        #expect(tabs[0].workingDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                == harness.paths.home.resolvingSymlinksInPath().path)
        let byPrefix = try await harness.control.describeSession(String(session.id.description.prefix(8)))
        #expect(byPrefix.id == session.id.description)
        await #expect(throws: ControlError.self) { _ = try await harness.control.describeSession("99") }
        harness.manager.close(session)
    }

    @Test func readScreenFallsBackToTranscriptWithoutRenderer() async throws {
        let harness = try Harness { $0.ai.inputPolicy = .allow }
        let session = try await harness.openReadyShell()
        _ = try await harness.control.runCommand("1", command: "echo screen-check", timeout: .seconds(10), client: assistant)
        let screen = try await harness.control.readScreen("1", scrollbackLines: 50, client: assistant)
        #expect(screen.text.contains("screen-check"))
        harness.manager.close(session)
    }

    @Test func policyDeniesInputWhenDisabled() async throws {
        let harness = try Harness { $0.ai.inputPolicy = .deny }
        let session = try await harness.openReadyShell()
        await #expect(throws: ControlError.self) {
            try await harness.control.sendInput("1", text: "echo nope\r", client: assistant)
        }
        let audit = AuditTrail(url: harness.paths.auditLog)
        try await Task.sleep(for: .milliseconds(200))
        #expect(audit.recent().first?.outcome == .denied)
        harness.manager.close(session)
    }

    @Test func askPolicyWithoutApproverFailsClosed() async throws {
        let harness = try Harness() // default: ask every time, and no approver attached
        let session = try await harness.openReadyShell()
        await #expect(throws: ControlError.self) {
            try await harness.control.sendInput("1", text: "echo nope\r", client: assistant)
        }
        harness.manager.close(session)
    }

    @Test func rejectsHostileDestinations() async throws {
        let harness = try Harness()
        await #expect(throws: ControlError.self) {
            _ = try await harness.control.openSession(.destination("-oProxyCommand=touch /tmp/pwned"), client: assistant)
        }
        #expect(harness.manager.sessions.isEmpty)
    }

    @Test func restoresUnsavedDestinationsAndSavedHosts() throws {
        let harness = try Harness()
        let saved = HostProfile(name: "saved", hostname: "saved.example.com")
        harness.hosts.upsert(saved)
        let adHoc = HostProfile(name: "x", hostname: "adhoc.example.com", user: "deploy", port: 2222)
        let restorer = SessionRestorer(paths: harness.paths)
        // Sessions are built without launching ssh; only their kinds matter here.
        let sessions = [TerminalSession(kind: .ssh(saved), configuration: nil),
                        TerminalSession(kind: .ssh(adHoc), configuration: nil)]
        let frame = CGRect(x: 120, y: 80, width: 1400, height: 900)
        restorer.save([RestorableWindow(sessions: sessions, frame: frame, selectedTab: 1)]) { harness.hosts.host(id: $0) != nil }

        let document = restorer.load()
        #expect(document.sessions.map(\.kind) == [.host(saved.id), .destination(adHoc)])
        #expect(document.sessions.allSatisfy { $0.windowIndex == 0 })
        #expect(document.window(0) == WindowSnapshot(index: 0, frame: frame, selectedTab: 1), "the window comes back where it was")
    }

    @Test func readsStateSavedBeforeWindowFramesExisted() throws {
        let harness = try Harness()
        try #"{ "version": 1, "sessions": [ { "kind": { "local": {} }, "windowIndex": 0 } ] }"#
            .write(to: harness.paths.sessionStateFile, atomically: true, encoding: .utf8)
        let document = SessionRestorer(paths: harness.paths).load()
        #expect(document.sessions.map(\.kind) == [.local])
        #expect(document.windows.isEmpty)
    }

    @Test func extractorReturnsOnlyCommandOutput() {
        let raw = Data("echo hi\r\n\u{1B}]133;C\u{07}hi\r\n\u{1B}]133;D;0\u{07}\u{1B}]7;file://mac/Users/me\u{1B}\\\u{1B}]133;A\u{07}❯ ".utf8)
        let (output, truncated) = CommandOutputExtractor.extract(raw, command: "echo hi", usesMarks: true)
        #expect(output == "hi")
        #expect(!truncated)
    }
}
