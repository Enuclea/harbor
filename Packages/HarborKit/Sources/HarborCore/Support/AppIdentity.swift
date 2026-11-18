import Foundation

/// Single source of truth for the product's identity.
///
/// The bundle identifier and marketing name are also set in `Config/Base.xcconfig`; the
/// fallbacks here are used by the command-line bridge and by tests, which have no app bundle.
public enum AppIdentity {
    public static let name = "Harbor"
    public static let defaultBundleIdentifier = "dev.harbor.Harbor"

    /// Version of the bundled shell-integration scripts. Bump when the scripts change so
    /// installed copies are refreshed and Doctor can flag stale shells.
    public static let shellIntegrationVersion = 3

    /// Carries a host's display name to its shell (see `HostProfile.showsNameInPrompt`).
    /// An `LC_*` name because most sshd configurations accept those by default; the
    /// remote integration moves it out of the `LC_*` namespace so it isn't forwarded on.
    public static let hostNameVariable = "LC_HARBOR_HOST"

    /// The running app's identifier, or the default when running outside an app bundle
    /// (the `harbor-mcp` bridge, `swift test`).
    public static var bundleIdentifier: String {
        guard Bundle.main.bundleURL.pathExtension == "app", let id = Bundle.main.bundleIdentifier else {
            return defaultBundleIdentifier
        }
        return id
    }

    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
    }

    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "2"
    }

    public static var userAgent: String { "\(name)/\(version)" }
}
