import Foundation
@testable import HarborCore
import Testing

@Suite("Settings persistence")
struct SettingsTests {
    @Test func missingKeysFallBackToDefaults() throws {
        let partial = #"{ "appearance": { "fontSize": 15 }, "futureSection": { "x": 1 } }"#
        let settings = try LenientJSON.decode(AppSettings.self, from: Data(partial.utf8), defaults: AppSettings())
        #expect(settings.appearance.fontSize == 15)
        #expect(settings.appearance.themeID == BuiltInThemes.defaultDarkID)
        #expect(settings.ssh.connectionSharing)
    }

    @Test func roundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "harbor-settings-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONFileStore(url: url) { AppSettings() }
        var settings = AppSettings()
        settings.terminal.scrollbackLines = 42
        settings.shell.prompt = PromptPreset.developer.config
        try store.save(settings)
        #expect(store.load().value == settings)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func corruptFileIsMovedAsideNotLost() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "harbor-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "settings.json")
        try Data("{ not json".utf8).write(to: url)
        let result = JSONFileStore(url: url) { AppSettings() }.load()
        #expect(result.recoveredFrom != nil)
        #expect(result.value == AppSettings())
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains("corrupt") }
        #expect(backups.count == 1)
    }

    @Test func hostProfilesDecodeLeniently() throws {
        let json = #"{ "hosts": [ { "hostname": "example.org", "colour": "ignored" } ] }"#
        let document = try LenientJSON.decode(HostDocument.self, from: Data(json.utf8), defaults: HostDocument())
        #expect(document.hosts.first?.name == "example.org")
        #expect(document.hosts.first?.color == HostColor.none)
    }

    @Test func themesHaveSixteenColours() {
        for theme in BuiltInThemes.all {
            #expect(theme.ansi.count == 16, "\(theme.name)")
        }
        #expect(BuiltInThemes.harborMidnight.isDark)
        #expect(!BuiltInThemes.harborDaylight.isDark)
    }

    @Test func fuzzyMatchingPrefersPrefixes() throws {
        let prefix = try #require(FuzzyMatcher.score("prod", in: "prod-api"))
        let scattered = try #require(FuzzyMatcher.score("prod", in: "p-r-o-d"))
        #expect(prefix > scattered)
        #expect(FuzzyMatcher.score("xyz", in: "prod-api") == nil)
    }
}
