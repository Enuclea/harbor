import HarborCore
import HarborShell
import SwiftUI

struct GeneralPane: View {
    @Bindable var store: SettingsStore
    let services: AppServices

    var body: some View {
        Form {
            Section("Shell") {
                Picker("Shell", selection: $store.settings.shell.shellPath) {
                    Text("Login shell (\(LoginShell.path))").tag(String?.none)
                    ForEach(LoginShell.available, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Toggle("Run as a login shell", isOn: $store.settings.shell.launchAsLoginShell)
                Toggle("Shell integration", isOn: $store.settings.shell.shellIntegration)
                Footnote("Integration reports the working directory and command results, so new tabs open in the same folder, ⌘↑/⌘↓ jump between prompts, the file browser follows along and assistants get exit codes. Your dotfiles are not modified.")
            }

            Section("Tabs") {
                Picker("New tabs open in", selection: $store.settings.terminal.newTabDirectory) {
                    ForEach(NewTabDirectory.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("When the shell exits", selection: $store.settings.terminal.exitBehavior) {
                    ForEach(ExitBehavior.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Ask before closing a tab that's running something", isOn: $store.settings.terminal.confirmCloseWithRunningProcess)
                Toggle("Reopen tabs when Harbor starts", isOn: $store.settings.terminal.restoreSessionsOnLaunch)
            }

            Section("Keyboard and mouse") {
                Toggle("Use Option as Meta key", isOn: $store.settings.terminal.optionAsMeta)
                Toggle("Copy text when selected", isOn: $store.settings.terminal.copyOnSelect)
            }

            Section("Bell") {
                Picker("Bell", selection: $store.settings.terminal.bell) {
                    Text("Off").tag(BellMode.none)
                    Text("Sound").tag(BellMode.sound)
                    Text("Flash").tag(BellMode.visual)
                    Text("Sound and flash").tag(BellMode.soundAndVisual)
                }
                Toggle("Bounce the Dock icon for bells in background tabs", isOn: $store.settings.terminal.notifyOnBackgroundBell)
            }

            Section("Clipboard access for programs") {
                Toggle("Allow programs to copy to the clipboard (OSC 52)", isOn: $store.settings.terminal.allowClipboardWrite)
                Toggle("Allow programs to read the clipboard", isOn: $store.settings.terminal.allowClipboardRead)
                if store.settings.terminal.allowClipboardRead {
                    Footnote("Any program in any tab — including on remote hosts — could read what you've copied, such as passwords.")
                        .foregroundStyle(.orange)
                }
            }

            Section("Scrollback") {
                Stepper(value: $store.settings.terminal.scrollbackLines, in: 1_000...1_000_000, step: 5_000) {
                    LabeledContent("Lines kept", value: store.settings.terminal.scrollbackLines.formatted())
                }
            }

            Section("Advanced") {
                TextField("TERM", text: $store.settings.terminal.termType)
                Footnote("Leave as xterm-256color unless a remote system lacks its terminfo entry.")
                Button("Run Onboarding Again…") { services.actions?.showOnboarding() }
            }
        }
        .formStyle(.grouped)
    }
}
