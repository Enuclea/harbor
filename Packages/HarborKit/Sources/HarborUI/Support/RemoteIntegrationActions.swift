import Foundation
import HarborCore
import HarborHostSetup
import HarborSSH

/// Installs, removes and inspects Harbor's shell integration on a host, and records the
/// result on the saved host so future tabs launch correctly.
@MainActor
enum RemoteIntegrationActions {
    static func inspect(_ host: HostProfile, services: AppServices) async throws -> RemoteIntegrationReport {
        try await run(host, services: services) { try await $0.inspect() }
    }

    static func install(_ host: HostProfile, services: AppServices) async throws -> RemoteIntegrationReport {
        let report = try await run(host, services: services) { try await $0.install() }
        record(report, for: host, services: services)
        return report
    }

    static func uninstall(_ host: HostProfile, services: AppServices) async throws {
        try await run(host, services: services) { try await $0.uninstall() }
        record(nil, for: host, services: services)
    }

    /// Saves the installed state and whether tabs must start the shell with the marker.
    static func record(_ report: RemoteIntegrationReport?, for host: HostProfile, services: AppServices) {
        guard var saved = services.hosts.host(id: host.id) else { return }
        saved.remoteIntegration = report?.isInstalled ?? false
        saved.remoteIntegrationMarker = report?.needsMarker ?? false
        services.hosts.upsert(saved)
    }

    private static func run<T: Sendable>(
        _ host: HostProfile, services: AppServices,
        _ body: @Sendable (RemoteIntegrationInstaller) async throws -> T
    ) async throws -> T {
        let builder = SSHCommandBuilder(settings: services.settings.settings.ssh, controlDirectory: services.paths.sshControl)
        let (installer, browser) = RemoteIntegrationInstaller.ssh(host: host, builder: builder)
        defer { Task { await browser.disconnect() } }
        return try await body(installer)
    }
}
