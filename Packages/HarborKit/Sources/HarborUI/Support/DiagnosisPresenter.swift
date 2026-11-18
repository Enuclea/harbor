import AppKit
import HarborAssist
import HarborCore
import HarborDoctor
import HarborSessions
import SwiftUI

/// Explains a failed SSH session in a sheet on its window, using the session's last output
/// and a quick reachability probe. Nothing is sent off the Mac unless the user clicks
/// "Explain with AI".
@MainActor
enum DiagnosisPresenter {
    static func present(for session: TerminalSession, actions: (any AppActions)?, assist: AssistService? = nil) {
        let window = NSApp.windows.first { ($0.windowController as? TerminalWindowController)?.contains(session) == true }
        let output = ANSIStripper.plainText(from: session.pipeline.replay.suffix(8_192))
        let findings = FailureAdvisor.diagnose(output: output, host: session.kind.host)
        let model = DiagnosisModel(findings: findings, host: session.kind.host, rawOutput: output, assist: assist)
        let controller = NSHostingController(rootView: DiagnosisView(model: model, actions: actions) { [weak window] in
            if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
        })
        controller.preferredContentSize = NSSize(width: 480, height: 390)
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
    let rawOutput: String
    let assist: AssistService?
    var reachability: Bool?
    var aiLoading = false
    var aiExplanation: AssistResult?
    var aiError: String?

    init(findings: [Diagnosis], host: HostProfile?, rawOutput: String = "", assist: AssistService? = nil) {
        self.findings = findings
        self.host = host
        self.rawOutput = rawOutput
        self.assist = assist
    }

    func probe() async {
        guard let host else { return }
        reachability = await FailureAdvisor.probeReachability(host: host.usesSSHConfigAlias ? host.hostname : host.hostname, port: host.port ?? 22)
    }

    func askAI() async {
        guard let assist, !aiLoading else { return }
        aiLoading = true
        aiError = nil
        do {
            aiExplanation = try await assist.explainFailure(context: AssistContext(
                shell: "ssh",
                isRemote: true,
                hostLabel: host?.destinationLabel,
                lastCommand: "ssh \(host?.destinationLabel ?? "")",
                lastExitCode: 255,
                rawOutput: rawOutput
            ))
        } catch {
            aiError = error.localizedDescription
        }
        aiLoading = false
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
            if model.findings.isEmpty && model.aiExplanation == nil {
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
                    if let ai = model.aiExplanation {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Onboard AI Analysis (\(ai.usage.totalTokens) tokens)", systemImage: "sparkles")
                                .font(.headline)
                                .foregroundStyle(.purple)
                            Text(ai.explanation)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    if let aiError = model.aiError {
                        Text(aiError).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            HStack {
                if let assist = model.assist, assist.config.enabled, model.aiExplanation == nil {
                    if model.aiLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await model.askAI() }
                        } label: {
                            Label("Explain with AI", systemImage: "sparkles")
                        }
                    }
                }
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480, height: 390)
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
