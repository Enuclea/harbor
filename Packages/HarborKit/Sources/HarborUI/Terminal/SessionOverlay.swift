import HarborDoctor
import HarborPTY
import HarborSessions
import SwiftUI

/// Floating status shown over a terminal: why a session ended and what to do next,
/// and a brief indicator while an AI assistant is acting on the tab.
struct SessionOverlay: View {
    let session: TerminalSession
    weak var actions: (any AppActions)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 10) {
                if let activity = session.assistantActivityAt, context.date.timeIntervalSince(activity) < 4 {
                    Label("Assistant is working in this tab", systemImage: "sparkles")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassCapsule()
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let ended = endedDescription {
                    endedBanner(ended)
                }
            }
            .animation(.smooth(duration: 0.25), value: session.assistantActivityAt)
        }
    }

    private var endedDescription: (title: String, status: TerminationStatus?)? {
        switch session.state {
        case .exited(let status): (status.isClean ? "Process completed" : "Process \(status)", status)
        case .failed(let message): (message, nil)
        default: nil
        }
    }

    private func endedBanner(_ ended: (title: String, status: TerminationStatus?)) -> some View {
        HStack(spacing: 14) {
            Image(systemName: ended.status?.isClean == true ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(ended.status?.isClean == true ? Color.secondary : Color.orange)
            Text(ended.title)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            if session.kind.host != nil, let status = ended.status,
               FailureAdvisor.shouldOfferDiagnosis(kind: true, exitCode: status.exitCode, lifetime: Date().timeIntervalSince(session.createdAt)) {
                Button("Diagnose") { DiagnosisPresenter.present(for: session, actions: actions) }
            }
            Button(session.kind.host != nil ? "Reconnect" : "Restart") { session.restart() }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .glassPanel(cornerRadius: 14)
    }
}
