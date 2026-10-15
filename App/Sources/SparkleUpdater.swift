import AppKit
import HarborUI
import Sparkle

/// Sparkle 2 updates. Disabled (and the menu item greyed out) until a feed URL and
/// EdDSA public key are set in Config/Local.xcconfig.
@MainActor
final class SparkleUpdater: NSObject, UpdateChecking {
    private let controller: SPUStandardUpdaterController?

    override init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        controller = feed.isEmpty || key.isEmpty
            ? nil
            : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
