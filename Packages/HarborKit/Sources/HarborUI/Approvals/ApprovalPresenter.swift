import AppKit
import HarborControl
import HarborCore
import HarborLogging
import HarborSessions

/// Asks the person at the Mac before an assistant types into a tab.
///
/// Session-targeted requests render inline on the target tab's overlay without stealing
/// window focus. App-level requests without a session fall back to a sheet. Unanswered
/// prompts are denied after two minutes.
@MainActor
final class ApprovalPresenter: ApprovalRequesting {
    private let windows: WindowCoordinator
    private let log = Log(.control)

    init(windows: WindowCoordinator) {
        self.windows = windows
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        if let session = windows.session(for: request.sessionID) {
            return await requestInlineApproval(request, in: session)
        }
        return await requestModalApproval(request)
    }

    private func requestInlineApproval(_ request: ApprovalRequest, in session: TerminalSession) async -> ApprovalDecision {
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
        if windows.focusedSessionID() != session.id {
            session.ringBell()
        }

        let decision: ApprovalDecision = await withCheckedContinuation { continuation in
            let resumer = DecisionResumer(continuation)
            let prompt = InlineApprovalPrompt(request: request) { choice in
                resumer.resume(choice)
            }
            session.pendingApproval = prompt

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(120))
                if resumer.resume(.deny), session.pendingApproval?.id == prompt.id {
                    session.pendingApproval = nil
                }
            }
        }

        session.pendingApproval = nil
        log.notice("inline approval for \(request.client.name): \(decision)")
        return decision
    }

    private func requestModalApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        let window = window(for: request.sessionID)
        if !NSApp.isActive {
            NSApp.requestUserAttention(.criticalRequest)
        }
        window?.makeKeyAndOrderFront(nil)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(request.client.name) wants to \(request.action.verb) “\(request.sessionTitle)”"
        alert.informativeText = "Only allow this if you asked the assistant to do it. Commands run with your permissions."
        if let detail = request.detail, !detail.isEmpty {
            alert.accessoryView = Self.preview(for: detail)
        }
        alert.addButton(withTitle: "Deny")
        if request.canRemember {
            alert.addButton(withTitle: "Allow for This Tab")
        }
        alert.addButton(withTitle: "Allow Once")
        alert.buttons.first?.keyEquivalent = "\u{1b}"

        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            let resumer = OnceResumer(continuation)
            if let window {
                alert.beginSheetModal(for: window) { resumer.resume($0) }
            } else {
                resumer.resume(alert.runModal())
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(120))
                if resumer.resume(.alertFirstButtonReturn), let window, let sheet = window.attachedSheet {
                    window.endSheet(sheet)
                }
            }
        }

        let decision: ApprovalDecision
        switch response {
        case .alertFirstButtonReturn: decision = .deny
        case .alertSecondButtonReturn: decision = request.canRemember ? .allowForSession : .allowOnce
        default: decision = .allowOnce
        }
        log.notice("approval for \(request.client.name): \(decision)")
        return decision
    }

    private func window(for sessionID: SessionID?) -> NSWindow? {
        windows.reveal(sessionID)
    }

    private static func preview(for text: String) -> NSView {
        let shown = text.replacingOccurrences(of: "\r", with: "⏎\n").trimmingCharacters(in: .newlines)
        let field = NSTextField(wrappingLabelWithString: String(shown.prefix(600)))
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.isSelectable = true
        field.frame = NSRect(x: 0, y: 0, width: 380, height: min(160, max(22, CGFloat(shown.split(separator: "\n").count) * 17)))
        return field
    }
}

/// Resumes a continuation once, whichever of the sheet or the timeout finishes first.
@MainActor
private final class OnceResumer {
    private var continuation: CheckedContinuation<NSApplication.ModalResponse, Never>?

    init(_ continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ response: NSApplication.ModalResponse) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: response)
        return true
    }
}

@MainActor
private final class DecisionResumer {
    private var continuation: CheckedContinuation<ApprovalDecision, Never>?

    init(_ continuation: CheckedContinuation<ApprovalDecision, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ decision: ApprovalDecision) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: decision)
        return true
    }
}

