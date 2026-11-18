import Darwin
import Foundation
import HarborControl
import HarborCore
import HarborLogging
@testable import HarborRemote
import os
import Testing

/// A canned control surface that records what the browser did.
private final class FakeTerminal: TerminalControlling, TerminalStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var _written = Data()
    var written: Data { lock.withLock { _written } }

    let summary = SessionSummary(
        id: "6c1d1f62-0000-0000-0000-000000000001", index: 1, title: "zsh", kind: "local", host: nil,
        workingDirectory: "/Users/me", foregroundProcess: "zsh", state: "running", exitCode: nil, isFocused: true,
        columns: 80, rows: 24, shellIntegration: "zsh", isAtPrompt: true, lastCommandExitCode: nil)

    func listSessions() async -> [SessionSummary] { [summary] }
    func describeSession(_ reference: String) async throws -> SessionSummary { summary }
    func openSession(_ request: OpenSessionRequest, client: ControlClient) async throws -> SessionSummary { summary }
    func focusSession(_ reference: String, client: ControlClient) async throws -> SessionSummary { summary }
    func closeSession(_ reference: String, client: ControlClient) async throws {}
    func sendInput(_ reference: String, text: String, client: ControlClient) async throws {}
    func readScreen(_ reference: String, scrollbackLines: Int, client: ControlClient) async throws -> ScreenContent {
        ScreenContent(sessionID: summary.id, columns: 80, rows: 24, cursorRow: 0, cursorColumn: 0, lines: ["hello"], scrollbackLineCount: 0)
    }
    func runCommand(_ reference: String, command: String, timeout: Duration, client: ControlClient) async throws -> CommandOutcome {
        CommandOutcome(output: "", exitCode: 0, completed: true, truncated: false, durationMilliseconds: 0)
    }
    func listHosts() async -> [HostSummary] { [] }

    func attach(_ sessionID: String, client: ControlClient, onOutput: @escaping @Sendable (Data) -> Void) async throws -> SessionAttachment {
        SessionAttachment(replay: Data("replayed-screen".utf8), size: .standard) {}
    }
    func write(_ sessionID: String, data: Data, client: ControlClient) async throws {
        lock.withLock { _written.append(data) }
    }
    func resize(_ sessionID: String, to size: TerminalSize, client: ControlClient) async {}
    func events() async -> AsyncStream<ControlEvent> { AsyncStream { _ in } }
}

/// Minimal HTTP/1.1 client over a raw socket, so tests can send any Host/Origin header.
private enum RawHTTP {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: String
    }

    static func send(port: Int, method: String = "GET", path: String, host: String = "127.0.0.1",
                     headers: [String: String] = [:], body: String? = nil) throws -> Response {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        var request = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n"
        for (name, value) in headers { request += "\(name): \(value)\r\n" }
        if let body { request += "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n" }
        request += "\r\n" + (body ?? "")
        _ = request.withCString { write(fd, $0, strlen($0)) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        let text = String(decoding: data, as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        let head = parts.first?.components(separatedBy: "\r\n") ?? []
        let status = Int(head.first?.split(separator: " ").dropFirst().first ?? "") ?? 0
        var parsed: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            parsed[name] = parsed[name].map { "\($0), \(value)" } ?? value
        }
        return Response(status: status, headers: parsed, body: parts.dropFirst().joined(separator: "\r\n\r\n"))
    }
}

private struct Fixture {
    let server: RemoteServer
    let authenticator: RemoteAuthenticator
    let keychain: KeychainStore
    let control: FakeTerminal
    let port: Int
    let token: String

    static func start(allowInput: Bool = true) async throws -> Fixture {
        let keychain = KeychainStore(service: "dev.harbor.tests.\(UUID().uuidString)")
        let audit = AuditTrail(url: FileManager.default.temporaryDirectory.appending(path: "audit-\(UUID()).jsonl"))
        let authenticator = RemoteAuthenticator(keychain: keychain, audit: audit)
        let control = FakeTerminal()
        var settings = RemoteAccessSettings()
        settings.enabled = true
        settings.allowInput = allowInput
        let frozen = settings
        let server = RemoteServer(control: control, authenticator: authenticator, allowlist: HostAllowlist()) { frozen }
        let port = try await server.start(port: 0)
        let token = try await authenticator.currentToken()
        return Fixture(server: server, authenticator: authenticator, keychain: keychain, control: control, port: port, token: token)
    }

    func stop() async {
        await server.stop()
        try? keychain.remove(RemoteAuthenticator.tokenAccount)
    }

    func signIn() throws -> String {
        let response = try RawHTTP.send(port: port, method: "POST", path: "/api/login",
                                        headers: ["Origin": "http://127.0.0.1:\(port)"], body: #"{"token":"\#(token)"}"#)
        #expect(response.status == 204)
        let cookie = try #require(response.headers["set-cookie"])
        return String(cookie.split(separator: ";").first ?? "")
    }
}

@Suite("Remote access server", .serialized)
struct RemoteServerTests {
    @Test func servesDashboardWithStrictHeaders() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        let response = try RawHTTP.send(port: fixture.port, path: "/")
        #expect(response.status == 200)
        #expect(response.body.contains("<title>Harbor</title>"))
        let csp = try #require(response.headers["content-security-policy"])
        #expect(csp.contains("script-src 'self'"))
        #expect(csp.contains("frame-ancestors 'none'"))
        #expect(response.headers["x-frame-options"] == "DENY")
        #expect(try RawHTTP.send(port: fixture.port, path: "/assets/vendor/xterm.js").status == 200)
        #expect(try RawHTTP.send(port: fixture.port, path: "/assets/../Package.swift").status == 404)
    }

    @Test func refusesUnknownHostsToStopDNSRebinding() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        #expect(try RawHTTP.send(port: fixture.port, path: "/", host: "evil.example").status == 421)
        #expect(try RawHTTP.send(port: fixture.port, path: "/", host: "localhost:\(fixture.port)").status == 200)
    }

    @Test func requiresSignInForAPIs() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        #expect(try RawHTTP.send(port: fixture.port, path: "/api/sessions").status == 401)
        let cookie = try fixture.signIn()
        let sessions = try RawHTTP.send(port: fixture.port, path: "/api/sessions", headers: ["Cookie": cookie])
        #expect(sessions.status == 200)
        #expect(sessions.body.contains("6c1d1f62"))
    }

    @Test func sessionCookieIsLockedDown() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        let response = try RawHTTP.send(port: fixture.port, method: "POST", path: "/api/login",
                                        headers: ["Origin": "http://127.0.0.1:\(fixture.port)"], body: #"{"token":"\#(fixture.token)"}"#)
        let cookie = try #require(response.headers["set-cookie"]).lowercased()
        #expect(cookie.contains("httponly"))
        #expect(cookie.contains("samesite=strict"))
        #expect(!cookie.contains("secure"), "plain-http loopback must not set Secure")

        let behindTunnel = try RawHTTP.send(port: fixture.port, method: "POST", path: "/api/login",
                                            headers: ["Origin": "http://127.0.0.1:\(fixture.port)", "X-Forwarded-Proto": "https"],
                                            body: #"{"token":"\#(fixture.token)"}"#)
        #expect(try #require(behindTunnel.headers["set-cookie"]).lowercased().contains("secure"))
    }

    @Test func rejectsCrossSiteRequests() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        let noOrigin = try RawHTTP.send(port: fixture.port, method: "POST", path: "/api/login", body: #"{"token":"\#(fixture.token)"}"#)
        #expect(noOrigin.status == 403)
        let foreign = try RawHTTP.send(port: fixture.port, method: "POST", path: "/api/login",
                                       headers: ["Origin": "https://evil.example"], body: #"{"token":"\#(fixture.token)"}"#)
        #expect(foreign.status == 403)
    }

    @Test func locksOutBruteForce() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        let headers = ["Origin": "http://127.0.0.1:\(fixture.port)", "CF-Connecting-IP": "203.0.113.9"]
        for _ in 0..<5 {
            let response = try RawHTTP.send(port: fixture.port, method: "POST", path: "/api/login", headers: headers, body: #"{"token":"guess"}"#)
            #expect(response.status == 401)
        }
        // Even the right token is refused while locked out.
        let locked = try RawHTTP.send(port: fixture.port, method: "POST", path: "/api/login", headers: headers,
                                      body: #"{"token":"\#(fixture.token)"}"#)
        #expect(locked.status == 429)
        #expect(locked.headers["retry-after"] != nil)
    }

    @Test func locksOutRotatingForwardedIPBruteForce() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        for attempt in 0..<15 {
            let headers = ["Origin": "http://127.0.0.1:\(fixture.port)", "CF-Connecting-IP": "198.51.100.\(attempt + 1)"]
            let response = try RawHTTP.send(port: fixture.port, method: "POST", path: "/api/login", headers: headers, body: #"{"token":"guess"}"#)
            #expect(response.status == 401)
        }
        let freshIPHeaders = ["Origin": "http://127.0.0.1:\(fixture.port)", "CF-Connecting-IP": "198.51.100.250"]
        let locked = try RawHTTP.send(port: fixture.port, method: "POST", path: "/api/login", headers: freshIPHeaders,
                                      body: #"{"token":"\#(fixture.token)"}"#)
        #expect(locked.status == 429)
    }

    @Test func rotatingTheTokenSignsEveryoneOut() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        let cookie = try fixture.signIn()
        _ = try await fixture.authenticator.rotateToken()
        #expect(try RawHTTP.send(port: fixture.port, path: "/api/sessions", headers: ["Cookie": cookie]).status == 401)
    }

    @Test func streamsTerminalOverWebSocket() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        let cookie = try fixture.signIn()

        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(fixture.port)/ws/sessions/\(fixture.control.summary.id)")!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("http://127.0.0.1:\(fixture.port)", forHTTPHeaderField: "Origin")
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        guard case .data(let replay) = try await task.receive() else {
            Issue.record("expected binary replay frame")
            return
        }
        #expect(String(decoding: replay, as: UTF8.self) == "replayed-screen")

        try await task.send(.string(#"{"type":"input","data":"ls\r"}"#))
        let deadline = ContinuousClock.now + .seconds(3)
        while fixture.control.written.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fixture.control.written == Data("ls\r".utf8))
    }
}

@Suite("Authenticator")
struct RemoteAuthenticatorTests {
    @Test func tokensAreLongAndComparedSafely() {
        let token = RemoteAuthenticator.randomToken()
        #expect(token.count >= 43)
        #expect(!token.contains("+") && !token.contains("/") && !token.contains("="))
        let digest = RemoteAuthenticator.digest(token)
        #expect(RemoteAuthenticator.constantTimeEqual(digest, RemoteAuthenticator.digest(token)))
        #expect(!RemoteAuthenticator.constantTimeEqual(digest, RemoteAuthenticator.digest(token + "x")))
    }

    @Test func allowlistParsesHostHeaders() {
        let allowlist = HostAllowlist()
        allowlist.allow("https://abc-def.trycloudflare.com")
        #expect(allowlist.permits(hostHeader: "abc-def.trycloudflare.com"))
        #expect(allowlist.permits(hostHeader: "127.0.0.1:47821"))
        #expect(allowlist.permits(hostHeader: "[::1]:47821"))
        #expect(!allowlist.permits(hostHeader: "evil.example"))
        #expect(!allowlist.permits(hostHeader: nil))
    }
}
