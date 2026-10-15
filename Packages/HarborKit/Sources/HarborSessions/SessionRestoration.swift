import CoreGraphics
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

/// Where a window was and which of its tabs was in front.
public struct WindowSnapshot: Codable, Sendable, Equatable {
    /// Matches `SessionSnapshot.windowIndex`.
    public var index: Int
    public var frame: CGRect?
    /// Position among the window's saved tabs.
    public var selectedTab: Int?

    public init(index: Int, frame: CGRect?, selectedTab: Int?) {
        self.index = index
        self.frame = frame
        self.selectedTab = selectedTab
    }
}

public struct SessionStateDocument: Codable, Sendable {
    public var version = 1
    public var sessions: [SessionSnapshot] = []
    public var windows: [WindowSnapshot] = []

    public init(sessions: [SessionSnapshot] = [], windows: [WindowSnapshot] = []) {
        self.sessions = sessions
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey { case version, sessions, windows }

    /// Lenient: files from before window snapshots existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sessions = try c.decodeIfPresent([SessionSnapshot].self, forKey: .sessions) ?? []
        windows = try c.decodeIfPresent([WindowSnapshot].self, forKey: .windows) ?? []
    }

    public func window(_ index: Int?) -> WindowSnapshot? {
        windows.first { $0.index == index }
    }
}

/// One open window, as handed to `SessionRestorer.save`.
public struct RestorableWindow {
    public var sessions: [TerminalSession]
    public var frame: CGRect?
    public var selectedTab: Int?

    public init(sessions: [TerminalSession], frame: CGRect? = nil, selectedTab: Int? = nil) {
        self.sessions = sessions
        self.frame = frame
        self.selectedTab = selectedTab
    }
}

/// Saves and restores windows and their tabs: local shells (in their last directory), saved
/// hosts, and unsaved SSH destinations, with each window's frame and front tab. One-off
/// commands (installers, ssh-copy-id) are not restored.
@MainActor
public struct SessionRestorer {
    private let store: JSONFileStore<SessionStateDocument>

    public init(paths: AppPaths) {
        store = JSONFileStore(url: paths.sessionStateFile) { SessionStateDocument() }
    }

    /// Saves windows front first. `isSaved` says whether a host is in the library (saved
    /// hosts are stored by id so later edits apply on restore).
    public func save(_ windows: [RestorableWindow], isSaved: (HostID) -> Bool) {
        var snapshots: [SessionSnapshot] = []
        var windowSnapshots: [WindowSnapshot] = []
        for (index, window) in windows.enumerated() {
            var saved = 0
            var selected: Int?
            for (position, session) in window.sessions.enumerated() {
                let kind: SessionSnapshot.Kind
                switch session.kind {
                case .localShell: kind = .local
                case .ssh(let host): kind = isSaved(host.id) ? .host(host.id) : .destination(host)
                case .command: continue
                }
                if position == window.selectedTab { selected = saved }
                snapshots.append(SessionSnapshot(kind: kind, workingDirectory: kind == .local ? session.workingDirectory : nil,
                                                 customTitle: session.customTitle, windowIndex: index))
                saved += 1
            }
            if saved > 0 { windowSnapshots.append(WindowSnapshot(index: index, frame: window.frame, selectedTab: selected)) }
        }
        try? store.save(SessionStateDocument(sessions: snapshots, windows: windowSnapshots))
    }

    public func load() -> SessionStateDocument {
        store.load().value
    }

    public func clear() {
        try? store.save(SessionStateDocument())
    }
}
