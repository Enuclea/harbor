import HarborControl
import HarborCore
import HarborDoctor
import HarborPTY
import HarborSessions
import SwiftUI

/// Floating status shown over a terminal: inline MCP approvals, Onboard AI assist chips,
/// why a session ended and what to do next, and a brief indicator while an assistant acts.
struct SessionOverlay: View {
    let session: TerminalSession
    let services: AppServices
    weak var actions: (any AppActions)?
    var onExplainFailure: ((Int32) -> Void)?
    var onSuggestContinuation: (() -> Void)?
    var onReconnectAll: (() -> Void)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 10) {
                if let prompt = session.pendingApproval {
                    approvalBanner(prompt)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let activity = session.assistantActivityAt, context.date.timeIntervalSince(activity) < 4 {
                    Label("Assistant is working in this tab", systemImage: "sparkles")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassCapsule()
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let chip = activeAssistChip(at: context.date) {
                    assistChipView(chip)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let connecting = connectingHost {
                    connectingBanner(connecting)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let ended = endedDescription {
                    endedBanner(ended)
                }
            }
            .animation(.smooth(duration: 0.25), value: session.assistantActivityAt)
            .animation(.smooth(duration: 0.2), value: session.pendingApproval?.id)
        }
    }

    // MARK: Inline MCP Approval

    private func approvalBanner(_ prompt: InlineApprovalPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(.orange)
                Text("\(prompt.request.client.name) wants to \(prompt.request.action.verb) “\(prompt.request.sessionTitle)”")
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            if let detail = prompt.request.detail, !detail.isEmpty {
                let preview = detail.replacingOccurrences(of: "\r", with: "⏎\n").trimmingCharacters(in: .newlines)
                Text(String(preview.prefix(400)))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 8) {
                Text("Runs with your permissions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Deny (Esc)") {
                    prompt.respond(.deny)
                }
                .keyboardShortcut(.cancelAction)

                if prompt.request.canRemember {
                    Button("Allow for Tab (⌥↩)") {
                        prompt.respond(.allowForSession)
                    }
                    .keyboardShortcut(.return, modifiers: [.option])
                }

                Button("Allow Once (⌘↩)") {
                    prompt.respond(.allowOnce)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 580)
        .glassPanel(cornerRadius: 14)
    }

    // MARK: Onboard AI Assist Chips

    private enum AssistChip {
        case failure(exitCode: Int32, startedAt: Date)
        case continuation(startedAt: Date)
    }

    private func activeAssistChip(at now: Date) -> AssistChip? {
        let onboard = services.settings.settings.ai.onboard
        guard onboard.enabled,
              session.state.isRunning,
              session.isAtPrompt,
              session.pendingApproval == nil,
              let command = session.lastCommand,
              let finishedAt = command.finishedAt,
              session.dismissedAssistForCommandAt != command.startedAt
        else { return nil }

        if onboard.offerOnCommandFailure,
           let code = command.exitCode,
           code != 0,
           code != 130,
           now.timeIntervalSince(finishedAt) < 60 {
            return .failure(exitCode: code, startedAt: command.startedAt)
        }
        if onboard.offerContinuation,
           (command.exitCode == nil || command.exitCode == 0),
           now.timeIntervalSince(finishedAt) < 25 {
            return .continuation(startedAt: command.startedAt)
        }
        return nil
    }

    private func assistChipView(_ chip: AssistChip) -> some View {
        HStack(spacing: 8) {
            switch chip {
            case .failure(let code, let startedAt):
                Button {
                    session.dismissedAssistForCommandAt = startedAt
                    onExplainFailure?(code)
                } label: {
                    Label("Explain exit \(code)", systemImage: "sparkles")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)

                Button {
                    session.dismissedAssistForCommandAt = startedAt
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

            case .continuation(let startedAt):
                Button {
                    session.dismissedAssistForCommandAt = startedAt
                    onSuggestContinuation?()
                } label: {
                    Label("Suggest Next Step", systemImage: "sparkles")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Button {
                    session.dismissedAssistForCommandAt = startedAt
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassCapsule()
    }

    // MARK: Ended Banner

    private var connectingHost: HostProfile? {
        guard case .ssh(let host) = session.kind,
              session.state.isRunning,
              !session.hasOutput
        else { return nil }
        return services.hosts.host(id: host.id) ?? host
    }

    private func connectingBanner(_ host: HostProfile) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connecting to \(host.name)…")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if host.destinationLabel != host.name {
                    Text(host.destinationLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !session.activePortForwards.isEmpty {
                    Text("⇄ " + session.activePortForwards.map(\.displaySummary).joined(separator: " · "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.teal)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("Cancel") {
                session.terminate()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 460)
        .glassPanel(cornerRadius: 14)
    }

    private var endedDescription: (title: String, status: TerminationStatus?)? {
        switch session.state {
        case .exited(let status): (status.isClean ? "Process completed" : "Process \(status)", status)
        case .failed(let message): (message, nil)
        default: nil
        }
    }

    private var disconnectedSSHCount: Int {
        services.sessions.sessions.filter { item in
            guard item.kind.host != nil else { return false }
            if case .exited(let status) = item.state { return !status.isClean }
            if case .failed = item.state { return true }
            return false
        }.count
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
            if session.kind.host != nil, disconnectedSSHCount > 1, let onReconnectAll {
                Button("Reconnect All (\(disconnectedSSHCount))") { onReconnectAll() }
            }
            Button(session.kind.host != nil ? "Reconnect" : "Restart") { session.restart() }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 620)
        .glassPanel(cornerRadius: 14)
    }
}

