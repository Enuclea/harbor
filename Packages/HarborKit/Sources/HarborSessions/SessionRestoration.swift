import Foundation
import HarborCore

/// What is saved at quit so tabs come back on the next launch.
public struct SessionSnapshot: Codable, Sendable, Equatable {
    public enum Kind: Codable, Sendable, Equatable {
        case local
        case host(HostID)
    }

    public var kind: Kind
    public var workingDirectory: String?
    public var customTitle: String?

    public init(kind: Kind, workingDirectory: String?, customTitle: String?) {
        self.kind = kind
        self.workingDirectory = workingDirectory
        self.customTitle = customTitle
    }
}

public struct SessionStateDocument: Codable, Sendable {
    public var version = 1
    public var sessions: [SessionSnapshot] = []

    public init(sessions: [SessionSnapshot] = []) {
        self.sessions = sessions
    }
}

/// Saves and restores open tabs. Ad-hoc SSH destinations and one-off commands are not
/// restored — only local shells (in their last directory) and saved hosts.
@MainActor
public struct SessionRestorer {
    private let store: JSONFileStore<SessionStateDocument>

    public init(paths: AppPaths) {
        store = JSONFileStore(url: paths.sessionStateFile) { SessionStateDocument() }
    }

    public func save(_ sessions: [TerminalSession]) {
        let snapshots: [SessionSnapshot] = sessions.compactMap { session in
            switch session.kind {
            case .localShell:
                return SessionSnapshot(kind: .local, workingDirectory: session.workingDirectory, customTitle: session.customTitle)
            case .ssh(let host):
                return SessionSnapshot(kind: .host(host.id), workingDirectory: nil, customTitle: session.customTitle)
            case .command:
                return nil
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
