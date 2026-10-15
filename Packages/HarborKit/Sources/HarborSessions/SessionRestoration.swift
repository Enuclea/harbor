import Foundation
import HarborCore

/// What is saved at quit so tabs come back on the next launch.
public struct SessionSnapshot: Codable, Sendable, Equatable {
    public enum Kind: Codable, Sendable, Equatable {
        case local
        /// A host from the user's library.
        case host(HostID)
        /// A destination typed into Quick Connect (or opened by an assistant) that isn't saved.
        case destination(HostProfile)
    }

    public var kind: Kind
    public var workingDirectory: String?
    public var customTitle: String?
    /// Which window the tab was in (tabs in the same window share an index).
    public var windowIndex: Int?

    public init(kind: Kind, workingDirectory: String?, customTitle: String?, windowIndex: Int? = nil) {
        self.kind = kind
        self.workingDirectory = workingDirectory
        self.customTitle = customTitle
        self.windowIndex = windowIndex
    }
}

public struct SessionStateDocument: Codable, Sendable {
    public var version = 1
    public var sessions: [SessionSnapshot] = []

    public init(sessions: [SessionSnapshot] = []) {
        self.sessions = sessions
    }
}

/// Saves and restores open tabs: local shells (in their last directory), saved hosts, and
/// unsaved SSH destinations. One-off commands (installers, ssh-copy-id) are not restored.
@MainActor
public struct SessionRestorer {
    private let store: JSONFileStore<SessionStateDocument>

    public init(paths: AppPaths) {
        store = JSONFileStore(url: paths.sessionStateFile) { SessionStateDocument() }
    }

    /// Saves tabs grouped by window, front window first. `isSaved` says whether a host is in
    /// the library (saved hosts are stored by id so later edits apply on restore).
    public func save(windows: [[TerminalSession]], isSaved: (HostID) -> Bool) {
        var snapshots: [SessionSnapshot] = []
        for (index, sessions) in windows.enumerated() {
            for session in sessions {
                switch session.kind {
                case .localShell:
                    snapshots.append(SessionSnapshot(kind: .local, workingDirectory: session.workingDirectory,
                                                     customTitle: session.customTitle, windowIndex: index))
                case .ssh(let host):
                    let kind: SessionSnapshot.Kind = isSaved(host.id) ? .host(host.id) : .destination(host)
                    snapshots.append(SessionSnapshot(kind: kind, workingDirectory: nil,
                                                     customTitle: session.customTitle, windowIndex: index))
                case .command:
                    continue
                }
            }
        }
        try? store.save(SessionStateDocument(sessions: snapshots))
    }

    public func load() -> [SessionSnapshot] {
        store.load().value.sessions
    }

    public func clear() {
        try? store.save(SessionStateDocument())
    }
}
