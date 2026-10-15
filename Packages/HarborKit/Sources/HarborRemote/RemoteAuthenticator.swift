import CryptoKit
import Foundation
import HarborCore
import HarborLogging

/// A signed-in browser.
public struct RemoteSession: Sendable, Equatable {
    public let id: String
    public let clientAddress: String
    public let userAgent: String
    public let createdAt: Date
    public let expiresAt: Date
}

public enum LoginResult: Sendable, Equatable {
    case success(RemoteSession)
    case invalidToken
    /// Too many failures from this address; try again after the given date.
    case rateLimited(until: Date)
}

/// Pairing-token verification, browser sessions and brute-force protection.
///
/// The access token is 256 random bits kept in the Keychain. Only its SHA-256 is held
/// in memory and compared in constant time. Sessions live in memory, so restarting
/// Harbor signs every browser out.
public actor RemoteAuthenticator {
    public static let tokenAccount = "remote-access-token"

    private let keychain: KeychainStore
    private let audit: AuditTrail
    private let log = Log(.remote)
    private var tokenDigest: Data?
    private var sessions: [String: RemoteSession] = [:]
    private var failures: [String: [Date]] = [:]
    private var lockouts: [String: Date] = [:]
    private var sessionLifetime: TimeInterval

    /// Failed attempts allowed per address within `failureWindow` before a lockout.
    private let maximumFailures = 5
    private let failureWindow: TimeInterval = 300
    private let lockoutDuration: TimeInterval = 900

    public init(keychain: KeychainStore, audit: AuditTrail, sessionLifetimeHours: Int = 12) {
        self.keychain = keychain
        self.audit = audit
        sessionLifetime = TimeInterval(max(1, sessionLifetimeHours)) * 3_600
    }

    // MARK: Token

    /// The current token, creating one on first use.
    public func currentToken() throws -> String {
        if let existing = try keychain.string(for: Self.tokenAccount), !existing.isEmpty {
            tokenDigest = Self.digest(existing)
            return existing
        }
        return try rotateToken()
    }

    /// Replaces the token and signs out every browser.
    @discardableResult
    public func rotateToken() throws -> String {
        let token = Self.randomToken()
        try keychain.set(token, for: Self.tokenAccount)
        tokenDigest = Self.digest(token)
        sessions.removeAll()
        log.notice("remote access token rotated; all browser sessions signed out")
        return token
    }

    public func setSessionLifetime(hours: Int) {
        sessionLifetime = TimeInterval(max(1, hours)) * 3_600
    }

    // MARK: Login

    public func login(token: String, clientAddress: String, userAgent: String, now: Date = Date()) -> LoginResult {
        if let until = lockouts[clientAddress], until > now {
            return .rateLimited(until: until)
        }
        if tokenDigest == nil { _ = try? currentToken() }
        guard let tokenDigest, Self.constantTimeEqual(Self.digest(token), tokenDigest) else {
            var recent = (failures[clientAddress] ?? []).filter { now.timeIntervalSince($0) < failureWindow }
            recent.append(now)
            failures[clientAddress] = recent
            if recent.count >= maximumFailures {
                lockouts[clientAddress] = now.addingTimeInterval(lockoutDuration)
                log.warning("locked out \(clientAddress) after \(recent.count) failed sign-ins")
            }
            audit.record(AuditRecord(actor: "web:\(clientAddress)", action: "login", outcome: .denied))
            return .invalidToken
        }
        failures[clientAddress] = nil
        let session = RemoteSession(
            id: Self.randomToken(), clientAddress: clientAddress, userAgent: String(userAgent.prefix(200)),
            createdAt: now, expiresAt: now.addingTimeInterval(sessionLifetime))
        sessions[session.id] = session
        audit.record(AuditRecord(actor: "web:\(clientAddress)", action: "login", detail: session.userAgent, outcome: .allowed))
        return .success(session)
    }

    public func session(for id: String?, now: Date = Date()) -> RemoteSession? {
        guard let id, let session = sessions[id] else { return nil }
        guard session.expiresAt > now else {
            sessions[id] = nil
            return nil
        }
        return session
    }

    public func logout(_ id: String) {
        sessions[id] = nil
    }

    public func signOutEveryone() {
        sessions.removeAll()
    }

    public var activeSessions: [RemoteSession] {
        let now = Date()
        return sessions.values.filter { $0.expiresAt > now }.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Primitives

    static func randomToken() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func digest(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }
}
