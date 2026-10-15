import Foundation
import HarborControl
import HarborCore
import HTTPTypes
import Hummingbird
import NIOCore

/// JSON endpoints used by the browser dashboard. All of them go through
/// `TerminalControlling`, so the browser gets exactly the powers policy allows.
struct RemoteAPI: Sendable {
    let control: any TerminalControlling
    let authenticator: RemoteAuthenticator
    let settings: @Sendable () async -> RemoteAccessSettings

    func register<Context: RequestContext>(on router: Router<Context>) {
        router.get("/api/status") { request, _ in try await status(request) }
        router.post("/api/login") { request, context in try await login(request, context) }
        router.post("/api/logout") { request, _ in try await logout(request) }
        router.get("/api/sessions") { _, _ in try json(await control.listSessions()) }
        router.post("/api/sessions") { request, context in try await openSession(request, context) }
        router.get("/api/sessions/:id/screen") { request, context in
            let id = try context.parameters.require("id")
            return try json(try await control.readScreen(id, scrollbackLines: 200, client: await client(request)))
        }
        router.post("/api/sessions/:id/focus") { request, context in
            let id = try context.parameters.require("id")
            return try json(try await control.focusSession(id, client: await client(request)))
        }
        router.delete("/api/sessions/:id") { request, context in
            let id = try context.parameters.require("id")
            try await control.closeSession(id, client: await client(request))
            return Response(status: .noContent)
        }
        router.get("/api/hosts") { _, _ in try json(await control.listHosts()) }
    }

    // MARK: Handlers

    private struct Status: Encodable {
        let app: String
        let version: String
        let authenticated: Bool
        let allowInput: Bool
        let allowOpeningSessions: Bool
    }

    private func status(_ request: Request) async throws -> Response {
        let session = await authenticator.session(for: request.cookies[AuthenticationMiddleware<BasicRequestContext>.cookieName]?.value)
        let remote = await settings()
        return try json(Status(app: AppIdentity.name, version: AppIdentity.version, authenticated: session != nil,
                               allowInput: remote.allowInput, allowOpeningSessions: remote.allowOpeningSessions))
    }

    private struct LoginBody: Decodable {
        let token: String
    }

    private func login<Context: RequestContext>(_ request: Request, _ context: Context) async throws -> Response {
        var request = request
        let body: LoginBody = try await decode(&request)
        let facts = RequestFacts(request)
        switch await authenticator.login(token: body.token.trimmingCharacters(in: .whitespacesAndNewlines),
                                         clientAddress: facts.clientAddress, userAgent: facts.userAgent) {
        case .success(let session):
            var response = Response(status: .noContent)
            response.setCookie(Cookie(
                name: AuthenticationMiddleware<Context>.cookieName, value: session.id,
                maxAge: Int(session.expiresAt.timeIntervalSince(session.createdAt)), path: "/",
                secure: facts.isHTTPS, httpOnly: true, sameSite: .strict))
            return response
        case .invalidToken:
            return try json(["error": "That access token isn't valid."], status: .unauthorized)
        case .rateLimited(let until):
            var response = try json(["error": "Too many attempts. Try again later."], status: .tooManyRequests)
            response.headers[.retryAfter] = String(Int(until.timeIntervalSinceNow.rounded(.up)))
            return response
        }
    }

    private func logout(_ request: Request) async throws -> Response {
        if let id = request.cookies[AuthenticationMiddleware<BasicRequestContext>.cookieName]?.value {
            await authenticator.logout(id)
        }
        var response = Response(status: .noContent)
        response.setCookie(Cookie(name: AuthenticationMiddleware<BasicRequestContext>.cookieName, value: "", maxAge: 0,
                                  path: "/", httpOnly: true, sameSite: .strict))
        return response
    }

    private struct OpenBody: Decodable {
        let type: String
        let host: String?
        let destination: String?
        let directory: String?
    }

    private func openSession<Context: RequestContext>(_ request: Request, _ context: Context) async throws -> Response {
        var request = request
        let body: OpenBody = try await decode(&request)
        let open: OpenSessionRequest
        switch body.type {
        case "local": open = .localShell(workingDirectory: body.directory)
        case "host": open = .savedHost(body.host ?? "")
        case "destination": open = .destination(body.destination ?? "")
        default: throw HTTPError(.badRequest, message: "type must be local, host or destination")
        }
        return try json(try await control.openSession(open, client: await client(request)), status: .created)
    }

    // MARK: Helpers

    func client(_ request: Request) async -> ControlClient {
        ControlClient(kind: .web, name: RequestFacts(request).clientAddress)
    }

    private func decode<T: Decodable>(_ request: inout Request) async throws -> T {
        let buffer = try await request.collectBody(upTo: 64 * 1024)
        do {
            return try JSONDecoder().decode(T.self, from: Data(String(buffer: buffer).utf8))
        } catch {
            throw HTTPError(.badRequest, message: "Invalid JSON body.")
        }
    }
}

/// Encodes a value as a JSON response.
func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    return Response(
        status: status,
        headers: [.contentType: "application/json; charset=utf-8"],
        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
}
