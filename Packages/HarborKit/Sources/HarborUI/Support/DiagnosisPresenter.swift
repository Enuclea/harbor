import AppKit
import HarborCore
import HarborDoctor
import HarborSessions
import SwiftUI

/// Explains a failed SSH session in a sheet on its window, using the session's last output
/// and a quick reachability probe. Nothing is sent off the Mac.
@MainActor
enum DiagnosisPresenter {
    static func present(for session: TerminalSession, actions: (any AppActions)?) {
        let window = NSApp.windows.first { ($0.windowController as? TerminalWindowController)?.contains(session) == true }
        let output = ANSIStripper.plainText(from: session.pipeline.replay.suffix(8_192))
        let findings = FailureAdvisor.diagnose(output: output, host: session.kind.host)
        let model = DiagnosisModel(findings: findings, host: session.kind.host)
        let controller = NSHostingController(rootView: DiagnosisView(model: model, actions: actions) { [weak window] in
            if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
        })
        controller.preferredContentSize = NSSize(width: 480, height: 360)
        if let window {
            window.beginSheet(NSWindow(contentViewController: controller))
        } else {
            NSWindow(contentViewController: controller).makeKeyAndOrderFront(nil)
        }
        Task { await model.probe() }
    }
}

@MainActor
@Observable
final class DiagnosisModel {
    let findings: [Diagnosis]
    let host: HostProfile?
    var reachability: Bool?

    init(findings: [Diagnosis], host: HostProfile?) {
        self.findings = findings
        self.host = host
    }

    func probe() async {
        guard let host else { return }
        reachability = await FailureAdvisor.probeReachability(host: host.usesSSHConfigAlias ? host.hostname : host.hostname, port: host.port ?? 22)
    }
}

struct DiagnosisView: View {
    let model: DiagnosisModel
    weak var actions: (any AppActions)?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Why the connection failed", systemImage: "stethoscope").font(.title3.weight(.semibold))
            if let host = model.host {
                HStack(spacing: 8) {
                    switch model.reachability {
                    case .none: ProgressView().controlSize(.small)
                    case .some(true): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .some(false): Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                    Text(reachabilityText(host)).font(.callout)
                }
            }
            if model.findings.isEmpty {
                Text("Harbor didn't recognise the error. The tab's output above usually says what ssh objected to; you can also run Diagnostics from the Help menu.")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.findings) { finding in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(finding.title).font(.headline)
                            Text(finding.explanation).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let remedy = finding.remedy {
                                Button(remedy.title) {
                                    actions?.perform(remedy)
                                    dismiss()
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480, height: 360)
    }

    private func reachabilityText(_ host: HostProfile) -> String {
        let target = "\(host.hostname):\(host.port ?? 22)"
        switch model.reachability {
        case .none: return "Checking whether \(target) is reachable…"
        case .some(true): return "\(target) accepts connections, so this is a sign-in problem."
        case .some(false): return "\(target) can't be reached from this Mac right now."
        }
    }
}
