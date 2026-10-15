import Foundation
import Observation

/// On-disk shape of `hosts.json`.
public struct HostDocument: Codable, Sendable {
    public var version = 1
    public var hosts: [HostProfile] = []

    public init(hosts: [HostProfile] = []) {
        self.hosts = hosts
    }
}

/// The user's saved SSH hosts.
@MainActor
@Observable
public final class HostLibrary {
    public private(set) var hosts: [HostProfile]

    @ObservationIgnored private let store: JSONFileStore<HostDocument>
    @ObservationIgnored public var onSaveError: (@MainActor (Error) -> Void)?

    public init(store: JSONFileStore<HostDocument>) {
        self.store = store
        hosts = store.load().value.hosts
    }

    public func host(id: HostID) -> HostProfile? {
        hosts.first { $0.id == id }
    }

    /// Inserts a new host or replaces the one with the same id.
    public func upsert(_ host: HostProfile) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        save()
    }

    public func remove(id: HostID) {
        hosts.removeAll { $0.id == id }
        save()
    }

    public func move(id: HostID, toIndex destination: Int) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        let host = hosts.remove(at: index)
        hosts.insert(host, at: min(max(0, destination), hosts.count))
        save()
    }

    public func markConnected(id: HostID, at date: Date = Date()) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].lastConnected = date
        save()
    }

    /// Adds hosts that aren't already present (same destination), returning how many were added.
    @discardableResult
    public func importHosts(_ candidates: [HostProfile]) -> Int {
        let existing = Set(hosts.map(\.destinationLabel))
        let fresh = candidates.filter { !existing.contains($0.destinationLabel) }
        hosts.append(contentsOf: fresh)
        if !fresh.isEmpty { save() }
        return fresh.count
    }

    /// Hosts ranked for Quick Connect: fuzzy match first, then favourites and recency.
    public func search(_ query: String) -> [HostProfile] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        let ranked: [(HostProfile, Int)] = hosts.compactMap { host in
            guard !trimmed.isEmpty else { return (host, 0) }
            return FuzzyMatcher.score(trimmed, in: host.searchText).map { (host, $0) }
        }
        return ranked.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.isFavorite != rhs.0.isFavorite { return lhs.0.isFavorite }
            return (lhs.0.lastConnected ?? .distantPast) > (rhs.0.lastConnected ?? .distantPast)
        }.map(\.0)
    }

    private func save() {
        do {
            try store.save(HostDocument(hosts: hosts))
        } catch {
            onSaveError?(error)
        }
    }
}
