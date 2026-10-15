import Foundation
import HarborControl
import HarborCore
import HarborLogging
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

public enum RemoteServerError: Error, LocalizedError {
    case assetsMissing
    case failedToStart(String)

    public var errorDescription: String? {
        switch self {
        case .assetsMissing: "The browser dashboard files are missing from the app bundle."
        case .failedToStart(let reason): "The remote access server couldn't start: \(reason)"
        }
    }
}

/// The HTTP + WebSocket server behind remote access. It binds to 127.0.0.1 only;
/// a tunnel (Cloudflare or Tailscale) is the sole way in from outside the Mac.
public actor RemoteServer {
    public private(set) var port: Int?
    private var task: Task<Void, Never>?
    private let control: any TerminalControlling & TerminalStreaming
    private let authenticator: RemoteAuthenticator
    private let allowlist: HostAllowlist
    private let settings: @Sendable () async -> RemoteAccessSettings
    private let log = Log(.remote)

    public init(
        control: any TerminalControlling & TerminalStreaming,
        authenticator: RemoteAuthenticator,
        allowlist: HostAllowlist,
        settings: @escaping @Sendable () async -> RemoteAccessSettings
    ) {
        self.control = control
        self.authenticator = authenticator
        self.allowlist = allowlist
        self.settings = settings
    }

    public var isRunning: Bool { task != nil && port != nil }

    /// Starts listening on `127.0.0.1:port` (0 picks a free port) and returns the bound port.
    @discardableResult
    public func start(port requestedPort: Int) async throws -> Int {
        if let port, task != nil { return port }
        let assets = StaticAssets()
        guard assets.isAvailable else { throw RemoteServerError.assetsMissing }

        let router = Router(context: BasicWebSocketRequestContext.self)
        router.add(middleware: HostCheckMiddleware(allowlist: allowlist))
        router.add(middleware: SecurityHeadersMiddleware())
        router.add(middleware: AuthenticationMiddleware(authenticator: authenticator, allowlist: allowlist))
        assets.register(on: router)
        RemoteAPI(control: control, authenticator: authenticator, settings: settings).register(on: router)

        let bridge = TerminalSocketBridge(streaming: control)
        router.ws("/ws/sessions/:id") { _, _ in
            .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            let id = try context.requestContext.parameters.require("id")
            let client = ControlClient(kind: .web, name: RequestFacts(context.request).clientAddress)
            try await bridge.run(sessionID: id, client: client, inbound: inbound, outbound: outbound)
        }

        let (bound, boundContinuation) = AsyncStream<Int>.makeStream()
        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: ApplicationConfiguration(address: .hostname("127.0.0.1", port: requestedPort), serverName: nil),
            onServerRunning: { channel in
                boundContinuation.yield(channel.localAddress?.port ?? requestedPort)
                boundContinuation.finish()
            },
            logger: .init(label: "harbor.remote"))

        let log = log
        task = Task {
            do {
                try await app.run()
            } catch {
                log.error("remote server stopped", error: error)
            }
            boundContinuation.finish()
        }

        var iterator = bound.makeAsyncIterator()
        guard let actualPort = await iterator.next() else {
            task?.cancel()
            task = nil
            throw RemoteServerError.failedToStart("port \(requestedPort) may already be in use")
        }
        port = actualPort
        log.notice("remote access server listening on 127.0.0.1:\(actualPort)")
        return actualPort
    }

    public func stop() async {
        task?.cancel()
        task = nil
        port = nil
        await authenticator.signOutEveryone()
        log.notice("remote access server stopped")
    }
}

/// Answers only to known host names (see `HostAllowlist`).
struct HostCheckMiddleware<Context: RequestContext>: RouterMiddleware {
    let allowlist: HostAllowlist

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard allowlist.permits(hostHeader: request.head.authority) else {
            return Response(status: .misdirectedRequest)
        }
        return try await next(request, context)
    }
}
