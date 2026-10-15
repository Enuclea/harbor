import Foundation
import HarborCore
import HarborPTY
@testable import HarborShell
import os
import Testing

/// End-to-end: a real interactive zsh launched the way Harbor launches it must emit the
/// OSC 7 / OSC 133 / OSC 1337 sequences that sessions rely on.
@Suite("Shell integration (live zsh)")
struct ShellIntegrationTests {
    @Test func zshReportsDirectoryAndCommandMarks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "harbor-int-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = ShellIntegrationLayout(root: root.appending(path: "shell"))
        try ShellIntegrationInstaller(layout: layout).install()
        try PromptInstaller(layout: layout, home: home).writePromptFiles(PromptPreset.harbor.config)

        let plan = ShellLaunchPlanner(layout: layout).plan(
            shellPath: "/bin/zsh", loginShell: false, integration: true, promptScope: .harborSessions, inheritedEnvironment: [:])
        var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8"]
        environment.merge(plan.environment) { $1 }

        let output = OSAllocatedUnfairLock(initialState: Data())
        let exited = AsyncStream<TerminationStatus>.makeStream()
        let process = try PTYProcess(
            .init(executable: plan.executable, argv0: plan.argv0, arguments: plan.arguments, environment: environment,
                  workingDirectory: home.path),
            onOutput: { data in output.withLock { $0.append(data) } },
            onExit: { exited.continuation.yield($0); exited.continuation.finish() })

        try await Task.sleep(for: .milliseconds(600))
        process.write("false\r")
        try await Task.sleep(for: .milliseconds(300))
        process.write("exit\r")
        for await _ in exited.stream { break }

        let text = output.withLock { String(decoding: $0, as: UTF8.self) }
        #expect(text.contains("\u{1b}]1337;HarborShellIntegration=zsh"))
        #expect(text.contains("\u{1b}]7;file://"))
        #expect(text.contains("\u{1b}]133;A"))
        #expect(text.contains("\u{1b}]133;C"))
        #expect(text.contains("\u{1b}]133;D;1"), "exit status of `false` should be reported")
        #expect(text.contains("\u{1b}]1337;HarborCommand=false\u{07}"), "the running command should be reported")
        #expect(text.contains("❯"), "Harbor prompt should be active")
    }
}
