import AppKit
import HarborDoctor
import HarborLogging
import HarborShell

/// Carries out a Doctor remedy after the user clicks it.
@MainActor
struct RemedyPerformer {
    let services: AppServices
    private let log = Log(.doctor)

    func perform(_ action: RemedyAction) {
        switch action {
        case .runInTerminal(let command, let title):
            services.actions?.runInNewTab(command, title: title)
        case .fixPermissions(let path, let mode):
            do {
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
                log.notice("set permissions of \(path) to \(String(mode, radix: 8))")
            } catch {
                log.error("couldn't fix permissions of \(path)", error: error)
            }
        case .reinstallShellIntegration:
            do {
                try ShellIntegrationInstaller(layout: services.shellLayout).install()
            } catch {
                log.error("couldn't reinstall shell integration", error: error)
            }
        case .openSettings(let section):
            services.actions?.openSettings(section: SettingsSection(remedyName: section))
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .revealInFinder(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}
