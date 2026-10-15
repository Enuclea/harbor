import AppKit
import HarborControl
import HarborCore
import HarborDoctor
import HarborFiles
import HarborLogging
import HarborMCP
import HarborRemote
import HarborSessions
import HarborShell
import HarborSSH

/// Every long-lived service, created once by `HarborAppController`. Views receive the
/// services they need from here rather than reaching for globals.
@MainActor
final class AppServices {
    let paths: AppPaths
    let settings: SettingsStore
    let hosts: HostLibrary
    let logFeed: LogFeed
    let fileLog: FileLogSink
    let audit: AuditTrail
    let keychain: KeychainStore
    let sessions: SessionManager
    let control: SessionControlService
    let mcp: MCPService
    let mcpRegistry: MCPClientRegistry
    let remote: RemoteAccessCoordinator
    let transfers = TransferCenter()
    let keys: SSHKeyManager
    let doctor = Doctor()
    let shellLayout: ShellIntegrationLayout

    /// Whether the control socket is accepting assistant connections.
    var mcpListening = false
    /// Set by the controller so panes can trigger app-level actions.
    weak var actions: AppActions?

    init(paths: AppPaths) {
        self.paths = paths
        try? paths.ensureDirectories()

        let settings = SettingsStore(store: JSONFileStore(url: paths.settingsFile) { AppSettings() })
        let logFeed = LogFeed()
        let logging = LoggingBootstrap.configure(paths: paths, level: settings.settings.logging.level, feed: logFeed)
        LoggingBootstrap.pruneOldFiles(in: [paths.logs, paths.sessionRecordings], olderThanDays: settings.settings.logging.retentionDays)

        self.settings = settings
        self.logFeed = logFeed
        fileLog = logging.file
        audit = logging.audit
        keychain = KeychainStore()
        hosts = HostLibrary(store: JSONFileStore(url: paths.hostsFile) { HostDocument() })
        sessions = SessionManager(settings: settings, hosts: hosts, paths: paths)
        control = SessionControlService(manager: sessions, hosts: hosts, settings: settings, audit: audit)
        mcp = MCPService(socketPath: paths.controlSocket.path, control: control)
        mcpRegistry = MCPClientRegistry(bridgePath: Self.bridgePath, home: paths.home)
        keys = SSHKeyManager(sshDirectory: paths.sshDirectory)
        shellLayout = ShellIntegrationLayout(paths: paths)
        remote = RemoteAccessCoordinator(control: control, keychain: keychain, audit: audit) {
            settings.settings.remote
        }
    }

    /// The `harbor-mcp` bridge shipped inside the app bundle.
    static var bridgePath: String {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/MacOS/harbor-mcp").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        // Running unbundled (e.g. from `swift run`): use the build directory's copy.
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "harbor-mcp").path
        return sibling
    }

    var currentTheme: TerminalTheme {
        let appearance = settings.settings.appearance
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let id = appearance.followSystemAppearance && !isDark ? appearance.lightThemeID : appearance.themeID
        return BuiltInThemes.themeOrDefault(id: id)
    }

    func theme(for session: TerminalSession) -> TerminalTheme {
        if let hostTheme = session.kind.host?.themeID, let theme = BuiltInThemes.theme(id: hostTheme) { return theme }
        return currentTheme
    }
}

/// App-level actions panes and windows can request without knowing the controller.
@MainActor
protocol AppActions: AnyObject {
    func openSettings(section: SettingsSection?)
    func openLocalTab(in directory: String?)
    func connect(to host: HostProfile)
    func runInNewTab(_ command: CommandSpec, title: String)
    func perform(_ remedy: Remedy)
    func showQuickConnect()
    func showOnboarding()
    /// The grid size of the frontmost terminal window's tab, if a terminal window is open.
    func frontTerminalSize() -> TerminalSize?
}
