import Foundation
import HTTPTypes
import Hummingbird

/// Facts about a request that matter for security decisions.
///
/// Harbor only listens on loopback, so every connection arrives from a local tunnel.
/// The real client address and scheme therefore come from the tunnel's headers.
struct RequestFacts {
    let clientAddress: String
    let isHTTPS: Bool
    let host: String?
    let origin: String?
    let userAgent: String

    init(_ request: Request) {
        let headers = request.headers
        func value(_ name: String) -> String? {
            HTTPField.Name(name).flatMap { headers[$0] }
        }
        let forwardedFor = value("X-Forwarded-For")?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        clientAddress = value("CF-Connecting-IP") ?? forwardedFor ?? "local"
        let proto = value("X-Forwarded-Proto")?.lowercased()
        isHTTPS = proto == "https" || (value("CF-Visitor")?.contains("https") ?? false)
        host = request.head.authority
        origin = value("Origin")
        userAgent = headers[.userAgent] ?? "unknown"
    }

    /// True when the request was made by a page on one of Harbor's own hosts. Comparing
    /// the Origin against the allowlist (not the Host header, which tunnels may rewrite)
    /// blocks cross-site requests and WebSocket hijacking.
    func hasAllowedOrigin(_ allowlist: HostAllowlist) -> Bool {
        guard let origin, let originHost = URL(string: origin)?.host else { return false }
        return allowlist.permits(hostHeader: originHost)
    }
}

/// Adds hardening headers to every response.
struct SecurityHeadersMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        var response = try await next(request, context)
        let host = request.head.authority ?? "localhost"
        let csp = [
            "default-src 'self'",
            "script-src 'self'",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' data:",
            "font-src 'self' data:",
            "connect-src 'self' wss://\(host) ws://\(host)",
            "frame-ancestors 'none'",
            "base-uri 'none'",
            "form-action 'none'",
        ].joined(separator: "; ")
        response.headers[.contentSecurityPolicy] = csp
        response.headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        response.headers[HTTPField.Name("X-Frame-Options")!] = "DENY"
        response.headers[HTTPField.Name("Referrer-Policy")!] = "no-referrer"
        response.headers[HTTPField.Name("Permissions-Policy")!] = "camera=(), microphone=(), geolocation=()"
        response.headers[HTTPField.Name("Cross-Origin-Opener-Policy")!] = "same-origin"
        if response.headers[.cacheControl] == nil {
            response.headers[.cacheControl] = "no-store"
        }
        return response
    }
}

/// Rejects unauthenticated access to everything except the login surface and static assets,
/// and rejects cross-origin state changes.
struct AuthenticationMiddleware<Context: RequestContext>: RouterMiddleware {
    let authenticator: RemoteAuthenticator
    let allowlist: HostAllowlist
    static var cookieName: String { "harbor_session" }

    static func isPublic(_ path: String) -> Bool {
        path == "/" || path == "/index.html" || path.hasPrefix("/assets/") || path == "/api/status" || path == "/api/login"
    }

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        let facts = RequestFacts(request)
        if request.method != .get, request.method != .head, !facts.hasAllowedOrigin(allowlist) {
            return Response(status: .forbidden)
        }
        if Self.isPublic(path) {
            return try await next(request, context)
        }
        guard await authenticator.session(for: request.cookies[Self.cookieName]?.value) != nil else {
            return Response(status: .unauthorized)
        }
        if path.hasPrefix("/ws/"), !facts.hasAllowedOrigin(allowlist) {
            return Response(status: .forbidden)
        }
        return try await next(request, context)
    }
}
