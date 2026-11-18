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

    @Test func tracksActivePortForwardsAndShowsInTabState() throws {
        let autoRule = try PortForwardRule.parse("8080:3000", label: "Web")
        let host = HostProfile(name: "nexus-tx", hostname: "nexus-tx", user: "dan", portForwards: [autoRule])
        let tab = sshTab(host)
        let model = WindowTabsModel()
        model.sessions = [tab]

        let initial = try #require(model.items.first)
        #expect(initial.activeForwardCount == 1)
        #expect(initial.tooltip.contains("localhost:8080 → 3000"))

        let socks = try PortForwardRule.parse("socks 1080")
        tab.recordActiveForward(socks)
        #expect(model.items.first?.activeForwardCount == 2)

        tab.removeActiveForward(id: autoRule.id)
        #expect(model.items.first?.activeForwardCount == 1)
    }

    @Test func portForwardModelAllowsRemoteHostPortCombosWithoutLocalPort() throws {
        let tempHome = FileManager.default.temporaryDirectory.appending(path: "harbor-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempHome) }
        let paths = AppPaths(
            applicationSupport: tempHome.appending(path: "support"),
            logs: tempHome.appending(path: "logs"),
            sshControl: tempHome.appending(path: "ssh"),
            home: tempHome
        )
        let services = AppServices(paths: paths)
        let host = HostProfile(name: "bastion", hostname: "bastion.example.com", user: "ops")
        let tab = sshTab(host)
        let pfModel = PortForwardModel(session: tab, services: services)

        #expect(!pfModel.canSubmitRedirect)

        // Entering an IP:port combo in the Remote field alone enables submission.
        pfModel.remotePortInput = "192.168.88.1:8291"
        #expect(pfModel.canSubmitRedirect)

        // Entering an IP:port combo in Target host alone also enables submission.
        pfModel.remotePortInput = ""
        pfModel.targetHostInput = "192.168.88.1:8291"
        #expect(pfModel.canSubmitRedirect)
    }

    @Test func openingSavedHostUsesLatestPortForwardsAndShowsSubtitleIndicator() throws {
        let rule = try PortForwardRule.build(kind: .local, localInput: "8291", remoteInput: "192.168.88.1:8291")
        let staleCopy = HostProfile(name: "Bastion", hostname: "bastion.example.com", user: "ops")
        var updatedCopy = staleCopy
        updatedCopy.portForwards = [rule]

        let tempHome = FileManager.default.temporaryDirectory.appending(path: "harbor-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempHome) }
        let paths = AppPaths(
            applicationSupport: tempHome.appending(path: "support"),
            logs: tempHome.appending(path: "logs"),
            sshControl: tempHome.appending(path: "ssh"),
            home: tempHome
        )
        let services = AppServices(paths: paths)
        services.saveAndSyncHost(updatedCopy)

        // Even if a caller passes an older HostProfile value with the same ID, the tab gets the saved forwards.
        let tab = TerminalSession(kind: .ssh(services.hosts.host(id: staleCopy.id) ?? staleCopy), configuration: nil)
        let tabsModel = WindowTabsModel()
        tabsModel.hosts = services.hosts
        tabsModel.sessions = [tab]

        let item = try #require(tabsModel.items.first)
        #expect(item.activeForwardCount == 1)
        #expect(item.subtitle?.contains("localhost:8291 → 192.168.88.1:8291") == true)
    }
}
