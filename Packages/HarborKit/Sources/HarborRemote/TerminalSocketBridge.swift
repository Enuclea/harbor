import Foundation
import HarborControl
import HarborCore
import HarborLogging
import HummingbirdWebSocket
import NIOCore
import os

/// Streams one session to a browser over WebSocket.
///
/// Server → browser: binary frames carry raw terminal output (the replay first, then live);
/// text frames carry JSON events (`closed`, `error`).
/// Browser → server: text frames with `{"type":"input","data":…}` or `{"type":"resize",…}`.
struct TerminalSocketBridge: Sendable {
    let streaming: any TerminalStreaming
    /// A browser that falls this far behind is disconnected rather than buffering forever.
    let maximumBacklog = 8 * 1024 * 1024
    private let log = Log(.remote)

    init(streaming: any TerminalStreaming) {
        self.streaming = streaming
    }

    func run(sessionID: String, client: ControlClient, inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter) async throws {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let backlog = OSAllocatedUnfairLock(initialState: 0)
        let limit = maximumBacklog
        let attachment: SessionAttachment
        do {
            attachment = try await streaming.attach(sessionID, client: client) { data in
                let overflow = backlog.withLock { pending -> Bool in
                    pending += data.count
                    return pending > limit
                }
                if overflow { continuation.finish() } else { continuation.yield(data) }
            }
        } catch {
            try await outbound.write(.text(Self.event("error", error.localizedDescription)))
            return
        }
        defer { attachment.detach() }
        log.info("browser \(client.name) attached to \(sessionID.prefix(8))")

        if !attachment.replay.isEmpty {
            try await outbound.write(.binary(ByteBuffer(bytes: attachment.replay)))
        }

        let events = await streaming.events()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await chunk in stream {
                    try await outbound.write(.binary(ByteBuffer(bytes: chunk)))
                    backlog.withLock { $0 -= chunk.count }
                }
                try await outbound.write(.text(Self.event("error", "Disconnected: the browser couldn't keep up with output.")))
            }
            group.addTask {
                for try await message in inbound.messages(maxSize: 1 << 20) {
                    guard case .text(let text) = message else { continue }
                    try await handle(text, sessionID: sessionID, client: client)
                }
            }
            group.addTask {
                for await event in events where event == .sessionClosed(sessionID) {
                    try await outbound.write(.text(Self.event("closed", "The tab was closed.")))
                    return
                }
            }
            try await group.next()
            group.cancelAll()
        }
        continuation.finish()
    }

    private struct ClientMessage: Decodable {
        let type: String
        let data: String?
        let cols: Int?
        let rows: Int?
    }

    private func handle(_ text: String, sessionID: String, client: ControlClient) async throws {
        guard let message = try? JSONDecoder().decode(ClientMessage.self, from: Data(text.utf8)) else { return }
        switch message.type {
        case "input":
            if let data = message.data { try? await streaming.write(sessionID, data: Data(data.utf8), client: client) }
        case "resize":
            if let cols = message.cols, let rows = message.rows, (2...1_000).contains(cols), (2...500).contains(rows) {
                await streaming.resize(sessionID, to: TerminalSize(columns: cols, rows: rows), client: client)
            }
        default:
            break
        }
    }

    static func event(_ type: String, _ message: String) -> String {
        let payload = ["type": type, "message": message]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
