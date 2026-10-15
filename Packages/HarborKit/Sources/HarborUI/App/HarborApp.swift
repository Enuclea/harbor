import AppKit
import HarborCore

/// The app's entry point. The app target's `main.swift` calls `HarborApp.run()`.
public enum HarborApp {
    @MainActor
    public static func run(updater: (any UpdateChecking)? = nil) -> Never {
        let application = NSApplication.shared
        let delegate = HarborApplicationDelegate(updater: updater)
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
        exit(0)
    }
}

@MainActor
final class HarborApplicationDelegate: NSObject, NSApplicationDelegate {
    private let controller: HarborAppController

    init(updater: (any UpdateChecking)?) {
        controller = HarborAppController(updater: updater)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.launch()
        NSApp.activate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.shouldTerminate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.willTerminate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { controller.reopen() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        controller.open(urls)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        controller.dockMenu()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// ⌘W in windows that aren't terminals (Settings, onboarding) closes the window.
    @objc func closeTab(_ sender: Any?) {
        NSApp.keyWindow?.performClose(sender)
    }
}
