import Foundation
import os

/// Host names the remote server answers to. Requests with any other `Host` header are
/// refused, which defeats DNS-rebinding attacks from web pages on the Mac's own browser.
public final class HostAllowlist: Sendable {
    private let hosts = OSAllocatedUnfairLock(initialState: Set(["localhost", "127.0.0.1", "[::1]", "::1"]))

    public init() {}

    /// Adds the public host of a tunnel URL or hostname.
    public func allow(_ hostOrURL: String) {
        let host = URL(string: hostOrURL)?.host ?? hostOrURL
        guard !host.isEmpty else { return }
        hosts.withLock { _ = $0.insert(host.lowercased()) }
    }

    public func remove(_ hostOrURL: String) {
        let host = URL(string: hostOrURL)?.host ?? hostOrURL
        hosts.withLock { _ = $0.remove(host.lowercased()) }
    }

    public func permits(hostHeader: String?) -> Bool {
        guard let hostHeader else { return false }
        let host: String
        if hostHeader.hasPrefix("[") {
            host = String(hostHeader.prefix { $0 != "]" }) + "]"
        } else {
            host = hostHeader.split(separator: ":").first.map(String.init) ?? hostHeader
        }
        return hosts.withLock { $0.contains(host.lowercased()) }
    }
}
