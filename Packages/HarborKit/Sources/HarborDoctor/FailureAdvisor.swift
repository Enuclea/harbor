import Foundation
import HarborCore
import HarborSSH
import Network

/// A specific explanation for why a connection failed, with the fix.
public struct Diagnosis: Sendable, Identifiable, Equatable {
    public var id: String { title }
    public let title: String
    public let explanation: String
    public let remedy: Remedy?
}

/// Explains failed SSH sessions from their last output — the event-triggered half of the
/// "agent on watch": it runs only when a tab fails, costs nothing, and nothing leaves the Mac.
public enum FailureAdvisor {
    /// True when a session ending like this deserves a "Diagnose" offer.
    public static func shouldOfferDiagnosis(kind isSSH: Bool, exitCode: Int32, lifetime: TimeInterval) -> Bool {
        isSSH && exitCode == 255 && lifetime < 120
    }

    /// Matches ssh's error messages against known failure modes.
    public static func diagnose(output: String, host: HostProfile?) -> [Diagnosis] {
        let text = output.lowercased()
        var findings: [Diagnosis] = []
        let destination = host?.hostname ?? "the host"

        if text.contains("remote host identification has changed") || text.contains("host key verification failed") {
            var remedy: Remedy?
            if let host {
                let target = host.port.map { "[\(host.hostname)]:\($0)" } ?? host.hostname
                remedy = Remedy("Forget the old key", .runInTerminal(CommandSpec("/usr/bin/ssh-keygen", ["-R", target]),
                                                                     title: "Remove old host key"))
            }
            findings.append(Diagnosis(
                title: "The server's identity changed",
                explanation: "\(destination) presented a different host key than last time. This is expected after a server is rebuilt, but it can also mean someone is intercepting the connection. Only remove the old key if you know why it changed.",
                remedy: remedy))
        }
        if text.contains("permission denied (publickey") || text.contains("no supported authentication methods") {
            findings.append(Diagnosis(
                title: "No key was accepted",
                explanation: "\(destination) only accepts key authentication and none of your keys are authorised. Install a key on the server, or pick the right key in the host's settings.",
                remedy: Remedy("Manage keys", .openSettings(section: "keys"))))
        }
        if text.contains("too many authentication failures") {
            findings.append(Diagnosis(
                title: "Too many keys were offered",
                explanation: "Your agent offered several keys and the server gave up before trying the right one. Set an identity file for this host so only that key is offered.",
                remedy: Remedy("Edit host", .openSettings(section: "hosts"))))
        }
        if text.contains("could not resolve hostname") || text.contains("nodename nor servname") {
            findings.append(Diagnosis(
                title: "The host name couldn't be found",
                explanation: "DNS has no address for \(destination). Check the spelling, your VPN, or whether the name only exists on another network.",
                remedy: nil))
        }
        if text.contains("connection refused") {
            findings.append(Diagnosis(
                title: "Nothing is accepting SSH connections",
                explanation: "\(destination) is reachable but refused the connection. sshd may be stopped, or it listens on a different port\(host?.port.map { " than \($0)" } ?? "").",
                remedy: nil))
        }
        if text.contains("operation timed out") || text.contains("connection timed out") || text.contains("no route to host") {
            findings.append(Diagnosis(
                title: "The server didn't answer",
                explanation: "Packets to \(destination) went unanswered. A firewall, VPN or network outage is the usual cause.",
                remedy: nil))
        }
        if text.contains("connection closed by") && findings.isEmpty {
            findings.append(Diagnosis(
                title: "The server closed the connection",
                explanation: "\(destination) hung up during sign-in. Fail2ban-style blocking, a MaxStartups limit or a misconfigured account are common causes.",
                remedy: nil))
        }
        return findings
    }

    /// Tries a TCP connection to the host's SSH port, to separate network trouble from
    /// authentication trouble.
    public static func probeReachability(host: String, port: Int, timeout: Duration = .seconds(5)) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let outcome = ProbeOutcome()
        return await withCheckedContinuation { continuation in
            outcome.arm(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: outcome.finish(true, connection)
                case .failed, .cancelled: outcome.finish(false, connection)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1_000))) {
                outcome.finish(false, connection)
            }
        }
    }
}

/// Ensures the probe's continuation resumes exactly once and is released immediately.
private final class ProbeOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    func arm(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func finish(_ value: Bool, _ connection: NWConnection) {
        let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { continuation = nil }
            return continuation
        }
        guard let pending else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending.resume(returning: value)
    }
}
