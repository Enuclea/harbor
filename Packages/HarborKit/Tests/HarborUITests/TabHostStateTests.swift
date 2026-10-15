import Foundation
import HarborCore
@testable import HarborSessions
@testable import HarborUI
import Observation
import Testing

private final class Flag: @unchecked Sendable {
    var raised = false
}

/// The tab menu's “Save as Host…” / “Edit Host…” state, and saved hosts' details on tabs.
@Suite("Tab host state")
@MainActor
struct TabHostStateTests {
    private func library(_ hosts: [HostProfile] = []) -> HostLibrary {
        let url = FileManager.default.temporaryDirectory.appending(path: "harbor-hosts-\(UUID().uuidString).json")
        let library = HostLibrary(store: JSONFileStore(url: url) { HostDocument() })
        hosts.forEach(library.upsert)
        return library
    }

    private func sshTab(_ host: HostProfile) -> TerminalSession {
        TerminalSession(kind: .ssh(host), configuration: nil)
    }

    @Test func offersSaveForUnsavedDestinationsAndEditForSavedHosts() {
        let adHoc = HostProfile(name: "nexus-tx", hostname: "nexus-tx", user: "dan")
        let library = library()
        let model = WindowTabsModel()
        model.hosts = library
        model.sessions = [sshTab(adHoc), TerminalSession(kind: .localShell, configuration: nil)]

        #expect(model.items.map(\.hostSaved) == [false, nil], "local tabs have no host action")

        library.upsert(adHoc)
        #expect(model.items.first?.hostSaved == true)
    }

    @Test func showsTheChosenNameWhenTheHostAsksForIt() {
        var host = HostProfile(name: "Nexus TX", hostname: "10.0.0.5", user: "dan")
        let tab = sshTab(host)
        #expect(TabItemState.firstLine(for: tab, host: host) == "dan@10.0.0.5")
        host.showsNameInPrompt = true
        #expect(TabItemState.firstLine(for: tab, host: host) == "dan@Nexus TX")
        host.user = nil
        #expect(TabItemState.firstLine(for: tab, host: host) == "Nexus TX")
    }

    @Test func tabsShowTheSavedHostsCurrentDetails() throws {
        var host = HostProfile(name: "nexus-tx", hostname: "nexus-tx", user: "dan")
        let library = library([host])
        let model = WindowTabsModel()
        model.hosts = library
        model.sessions = [sshTab(host)]

        let changed = Flag()
        withObservationTracking { _ = model.items } onChange: { changed.raised = true }
        host.color = .orange
        host.name = "Nexus TX"
        library.upsert(host)

        #expect(changed.raised, "editing the host redraws the strip")
        let item = try #require(model.items.first)
        #expect(item.hostColor == .orange, "the library's colour, not the one the tab opened with")
        #expect(item.title == "dan@nexus-tx")
    }
}
