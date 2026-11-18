import AppKit
import HarborCore
import HarborDoctor
import SwiftUI

struct SSHPane: View {
    @Bindable var store: SettingsStore
    let services: AppServices

    var body: some View {
        Form {
            Section("Connections") {
                Toggle("Share one sign-in per host", isOn: $store.settings.ssh.connectionSharing)
                Footnote("Tabs to the same host, the file browser and key installation reuse the first tab's authenticated connection (OpenSSH ControlMaster), so you sign in — and answer 2FA — once.")
                if store.settings.ssh.connectionSharing {
                    Stepper(value: $store.settings.ssh.connectionPersistSeconds, in: 0...7_200, step: 60) {
                        LabeledContent("Keep open after last tab closes",
                                       value: Duration.seconds(store.settings.ssh.connectionPersistSeconds).formatted(.units(allowed: [.hours, .minutes])))
                    }
                }
                Stepper(value: $store.settings.ssh.serverAliveInterval, in: 0...300, step: 5) {
                    LabeledContent("Keep-alive interval", value: store.settings.ssh.serverAliveInterval == 0 ? "Off" : "\(store.settings.ssh.serverAliveInterval) s")
                }
                Toggle("Automatically reconnect dropped SSH sessions", isOn: $store.settings.ssh.autoReconnectDroppedSessions)
                Footnote("When an SSH connection drops unexpectedly (exit status 255), Harbor automatically retries once after a short backoff.")
            }
            Section("Keys and agent") {
                Toggle("Forward agent to every host", isOn: $store.settings.ssh.forwardAgentByDefault)
                Toggle("Remember key passphrases in Keychain", isOn: $store.settings.ssh.storePassphrasesInKeychain)
            }
            Section("Advanced") {
                TextField("ssh executable", text: $store.settings.ssh.sshPath)
                HStack {
                    Button("Open ~/.ssh/config") { openConfig() }
                    Button("Show ~/.ssh in Finder") { NSWorkspace.shared.open(services.paths.sshDirectory) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func openConfig() {
        let url = services.paths.sshConfig
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data("# SSH client configuration — see `man ssh_config`\n".utf8),
                                           attributes: [.posixPermissions: 0o600])
        }
        NSWorkspace.shared.open(url)
    }
}

/// Lets panes probe reachability without depending on the advisor's API shape.
enum FailureAdvisorProxy {
    static func probe(host: String, port: Int) async -> Bool {
        await FailureAdvisor.probeReachability(host: host, port: port)
    }
}
