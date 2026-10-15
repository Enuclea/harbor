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

/// Saves and restores open tabs. Ad-hoc SSH destinations and one-off commands are not
/// restored — only local shells (in their last directory) and saved hosts.
@MainActor
public struct SessionRestorer {
    private let store: JSONFileStore<SessionStateDocument>

    public init(paths: AppPaths) {
        store = JSONFileStore(url: paths.sessionStateFile) { SessionStateDocument() }
    }

    /// Saves tabs grouped by window, front window first.
    public func save(windows: [[TerminalSession]]) {
        var snapshots: [SessionSnapshot] = []
        for (index, sessions) in windows.enumerated() {
            for session in sessions {
                switch session.kind {
                case .localShell:
                    snapshots.append(SessionSnapshot(kind: .local, workingDirectory: session.workingDirectory,
                                                     customTitle: session.customTitle, windowIndex: index))
                case .ssh(let host):
                    snapshots.append(SessionSnapshot(kind: .host(host.id), workingDirectory: nil,
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
