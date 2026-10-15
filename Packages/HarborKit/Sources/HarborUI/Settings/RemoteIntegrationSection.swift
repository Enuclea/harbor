import HarborCore
import HarborHostSetup
import SwiftUI

/// Host editor section: install, update or remove Harbor's shell integration on the host.
struct RemoteIntegrationSection: View {
    let host: HostProfile
    let services: AppServices
    /// Reports the new installed / marker flags so the editor's copy stays in sync.
    let onChange: (_ installed: Bool, _ needsMarker: Bool) -> Void
    @State private var report: RemoteIntegrationReport?
    @State private var working: String?
    @State private var error: String?

    var body: some View {
        Footnote("Lets this host's tabs show what's running, exit codes and the current folder — including commands you type yourself. Harbor copies its scripts to ~/.harbor/shell and adds a marked block to your shell's startup file that only loads in interactive Harbor sessions.")
        LabeledContent("Status") {
            if let working {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(working).foregroundStyle(.secondary)
                }
            } else if let error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let report {
                Text(report.summary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(host.remoteIntegration ? "Installed" : "Not installed").foregroundStyle(.secondary)
            }
        }
        HStack {
            Button("Check") { perform("Checking…") { try await RemoteIntegrationActions.inspect(host, services: services) } }
            Button(report?.isInstalled == true && report?.isCurrent == false ? "Update" : "Install") {
                perform("Installing…") { try await RemoteIntegrationActions.install(host, services: services) }
            }
            Button("Remove", role: .destructive) {
                perform("Removing…") {
                    try await RemoteIntegrationActions.uninstall(host, services: services)
                    return RemoteIntegrationReport(loginShell: nil, markerForwarded: true, installedVersion: nil, configuredShells: [])
                }
            }
            .disabled(!(report?.isInstalled ?? host.remoteIntegration))
        }
        .disabled(working != nil)
        Footnote("Uses this host's existing connection. If it signs in with a password, open a tab to it first.")
    }

    private func perform(_ label: String, _ operation: @escaping @MainActor () async throws -> RemoteIntegrationReport) {
        working = label
        error = nil
        Task {
            do {
                let result = try await operation()
                report = result
                onChange(result.isInstalled, result.isInstalled && result.needsMarker)
            } catch {
                self.error = error.localizedDescription
            }
            working = nil
        }
    }
}
