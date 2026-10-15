import AppKit
import HarborUI

// The app target is deliberately thin: everything lives in the HarborKit package so it
// builds and tests without Xcode. This file only adds what needs the app bundle (Sparkle).
MainActor.assumeIsolated {
    let updater = SparkleUpdater()
    HarborApp.run(updater: updater)
}
