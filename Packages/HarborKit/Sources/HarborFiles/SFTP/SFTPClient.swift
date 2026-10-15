import Foundation
import HarborLogging

/// Reports transfer progress: bytes completed, and the total when known.
public typealias TransferProgress = @Sendable (_ completed: Int64, _ total: Int64?) -> Void

/// An SFTP v3 client over any `SFTPTransport`.
///
/// Requests are multiplexed by id, so many can be in flight at once; transfers keep a
/// window of 32 × 32 KiB requests outstanding, which saturates typical links where a
/// request-at-a-time client would be bound by round-trip latency.
public actor SFTPClient {
    public static let chunkSize = 32 * 1024
    public static let window = 32

    private let transport: any SFTPTransport
    private let log = Log(.sftp)
    private var nextID: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<SFTPResponse, Error>] = [:]
    private var versionWaiter: CheckedContinuation<UInt32, Error>?
    private var reader: Task<Void, Never>?
    private var buffer = Data()
    private var failure: SFTPError?

    public init(transport: any SFTPTransport) {
        self.transport = transport
    }

    public var isOpen: Bool { reader != nil && failure == nil }

    // MARK: Lifecycle

    public func connect(timeout: Duration = .seconds(20)) async throws {
        startReader()
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.failVersion(SFTPError.disconnected("Timed out connecting to the server."))
        }
        defer { timer.cancel() }
        let version = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt32, Error>) in
            if let failure {
                continuation.resume(throwing: failure)
                return
            }
            versionWaiter = continuation
            transport.send(SFTPWriter.packet(type: .initialize) { $0.uint32(3) })
        }
        guard version >= 3 else { throw SFTPError.protocolViolation("server speaks SFTP v\(version)") }
    }

    public func disconnect() {
        transport.close()
    }

    // MARK: Paths and metadata

    public func realPath(_ path: String) async throws -> String {
        guard case .names(let names) = try await request(.realpath, { $0.string(path) }), let first = names.first else {
            throw SFTPError.unexpectedResponse
        }
        return first.filename
    }

    public func stat(_ path: String) async throws -> SFTPAttributes {
        try attributes(from: await request(.stat, { $0.string(path) }))
    }

    public func lstat(_ path: String) async throws -> SFTPAttributes {
        try attributes(from: await request(.lstat, { $0.string(path) }))
    }

    public func listDirectory(_ path: String) async throws -> [SFTPName] {
        let handle = try handle(from: await request(.opendir, { $0.string(path) }))
        var names: [SFTPName] = []
        do {
            while true {
                switch try await request(.readdir, { $0.bytes(handle) }) {
                case .names(let batch): names += batch
                case .status(.endOfFile, _):
                    try await closeHandle(handle)
                    return names.filter { $0.filename != "." && $0.filename != ".." }
                case .status(let code, let message): throw SFTPError.status(code, message)
                default: throw SFTPError.unexpectedResponse
                }
            }
        } catch {
            try? await closeHandle(handle)
            throw error
        }
    }

    // MARK: Mutations

    public func makeDirectory(_ path: String, permissions: UInt32 = 0o755) async throws {
        try expectOK(await request(.mkdir, { $0.string(path); $0.attributes(SFTPAttributes(permissions: permissions)) }))
    }

    public func removeFile(_ path: String) async throws {
        try expectOK(await request(.remove, { $0.string(path) }))
    }

    public func removeDirectory(_ path: String) async throws {
        try expectOK(await request(.rmdir, { $0.string(path) }))
    }

    public func rename(_ path: String, to newPath: String) async throws {
        try expectOK(await request(.rename, { $0.string(path); $0.string(newPath) }))
    }

    public func setPermissions(_ path: String, _ permissions: UInt32) async throws {
        try expectOK(await request(.setstat, { $0.string(path); $0.attributes(SFTPAttributes(permissions: permissions)) }))
    }

    // MARK: File handles

    public func openFile(_ path: String, flags: SFTPOpenFlags, attributes: SFTPAttributes = SFTPAttributes()) async throws -> Data {
        try handle(from: await request(.open, { $0.string(path); $0.uint32(flags.rawValue); $0.attributes(attributes) }))
    }

    public func closeHandle(_ handle: Data) async throws {
        try expectOK(await request(.close, { $0.bytes(handle) }))
    }

    /// Returns nil at end of file. May return fewer bytes than requested.
    public func read(_ handle: Data, offset: UInt64, length: UInt32) async throws -> Data? {
        switch try await request(.read, { $0.bytes(handle); $0.uint64(offset); $0.uint32(length) }) {
        case .data(let data): return data
        case .status(.endOfFile, _): return nil
        case .status(let code, let message): throw SFTPError.status(code, message)
        default: throw SFTPError.unexpectedResponse
        }
    }

    public func write(_ handle: Data, offset: UInt64, data: Data) async throws {
        try expectOK(await request(.write, { $0.bytes(handle); $0.uint64(offset); $0.bytes(data) }))
    }

    // MARK: Whole files

    /// Reads a small file into memory (for config files, not transfers).
    public func readFile(_ path: String, limit: Int = 4 * 1024 * 1024) async throws -> Data {
        let handle = try await openFile(path, flags: .read)
        var data = Data()
        do {
            while let chunk = try await read(handle, offset: UInt64(data.count), length: UInt32(Self.chunkSize)), !chunk.isEmpty {
                data.append(chunk)
                if data.count > limit { throw SFTPError.status(.failure, "\(path) is too large to edit.") }
            }
            try await closeHandle(handle)
        } catch {
            try? await closeHandle(handle)
            throw error
        }
        return data
    }

    /// Replaces a file's contents and sets its permissions.
    public func writeFile(_ path: String, contents: Data, permissions: UInt32) async throws {
        let bytes = Data(contents)
        let handle = try await openFile(path, flags: [.write, .create, .truncate], attributes: SFTPAttributes(permissions: permissions))
        do {
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + Self.chunkSize, bytes.count)
                try await write(handle, offset: UInt64(offset), data: bytes.subdata(in: offset..<end))
                offset = end
            }
            try await closeHandle(handle)
        } catch {
            try? await closeHandle(handle)
            throw error
        }
        // Attributes given to OPEN only apply when the file is created.
        try await setPermissions(path, permissions)
    }

    // MARK: Transfers

    /// Downloads `remotePath` to `localURL`, replacing it. A failed or cancelled download
    /// leaves no partial file behind.
    public func download(_ remotePath: String, to localURL: URL, progress: TransferProgress) async throws {
        let total = try await stat(remotePath).size.map(Int64.init)
        let handle = try await openFile(remotePath, flags: .read)
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let file = try FileHandle(forWritingTo: localURL)
        var inflight: [(offset: UInt64, length: UInt32, task: Task<Data?, Error>)] = []
        do {
            var nextOffset: UInt64 = 0
            var completed: Int64 = 0
            var reachedEnd = false
            while true {
                try Task.checkCancellation()
                while !reachedEnd, inflight.count < Self.window, total.map({ nextOffset < UInt64($0) }) ?? true {
                    let offset = nextOffset
                    let length = UInt32(Self.chunkSize)
                    inflight.append((offset, length, Task { try await self.read(handle, offset: offset, length: length) }))
                    nextOffset += UInt64(length)
                }
                guard !inflight.isEmpty else { break }
                let item = inflight.removeFirst()
                guard let data = try await item.task.value else {
                    reachedEnd = true
                    continue
                }
                try file.seek(toOffset: item.offset)
                try file.write(contentsOf: data)
                completed += Int64(data.count)
                progress(completed, total)
                if data.count < Int(item.length), !reachedEnd {
                    // Short read: ask again for the remainder of this range.
                    let offset = item.offset + UInt64(data.count)
                    let length = item.length - UInt32(data.count)
                    inflight.append((offset, length, Task { try await self.read(handle, offset: offset, length: length) }))
                }
            }
            try file.close()
            try await closeHandle(handle)
            log.info("downloaded \(remotePath)", ["bytes": "\(completed)"])
        } catch {
            inflight.forEach { $0.task.cancel() }
            try? file.close()
            try? FileManager.default.removeItem(at: localURL)
            try? await closeHandle(handle)
            throw error
        }
    }

    /// Uploads `localURL` to `remotePath`, replacing it.
    public func upload(_ localURL: URL, to remotePath: String, permissions: UInt32? = nil, progress: TransferProgress) async throws {
        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }
        let total = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        let handle = try await openFile(remotePath, flags: [.write, .create, .truncate], attributes: SFTPAttributes(permissions: permissions))
        var inflight: [(size: Int, task: Task<Void, Error>)] = []
        do {
            var offset: UInt64 = 0
            var completed: Int64 = 0
            var localEOF = false
            while true {
                try Task.checkCancellation()
                while !localEOF, inflight.count < Self.window {
                    guard let chunk = try file.read(upToCount: Self.chunkSize), !chunk.isEmpty else {
                        localEOF = true
                        break
                    }
                    let at = offset
                    offset += UInt64(chunk.count)
                    inflight.append((chunk.count, Task { try await self.write(handle, offset: at, data: chunk) }))
                }
                guard !inflight.isEmpty else { break }
                let item = inflight.removeFirst()
                try await item.task.value
                completed += Int64(item.size)
                progress(completed, total)
            }
            try await closeHandle(handle)
            log.info("uploaded \(remotePath)", ["bytes": "\(completed)"])
        } catch {
            inflight.forEach { $0.task.cancel() }
            try? await closeHandle(handle)
            throw error
        }
    }

    // MARK: Plumbing

    private func request(_ type: SFTPPacketType, _ build: (inout SFTPWriter) -> Void) async throws -> SFTPResponse {
        if let failure { throw failure }
        let id = nextID
        nextID = nextID == UInt32.max ? 1 : nextID + 1
        let packet = SFTPWriter.packet(type: type) { writer in
            writer.uint32(id)
            build(&writer)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            transport.send(packet)
        }
    }

    private func startReader() {
        guard reader == nil else { return }
        let incoming = transport.incoming
        reader = Task { [weak self] in
            for await chunk in incoming {
                await self?.receive(chunk)
            }
            await self?.connectionEnded()
        }
    }

    private func receive(_ chunk: Data) {
        buffer.append(chunk)
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= 16 * 1024 * 1024 else {
                fail(.protocolViolation("invalid packet length \(length)"))
                return
            }
            guard buffer.count >= 4 + length else { return }
            let packet = buffer.subdata(in: (start + 4)..<(start + 4 + length))
            buffer.removeSubrange(start..<(start + 4 + length))
            do {
                let (id, response) = try SFTPResponse.decode(packet)
                if case .version(let version) = response {
                    versionWaiter?.resume(returning: version)
                    versionWaiter = nil
                } else {
                    pending.removeValue(forKey: id)?.resume(returning: response)
                }
            } catch {
                fail(.protocolViolation("undecodable packet"))
                return
            }
        }
    }

    private func connectionEnded() {
        fail(.disconnected(transport.closeReason))
    }

    private func failVersion(_ error: SFTPError) {
        versionWaiter?.resume(throwing: error)
        versionWaiter = nil
        transport.close()
    }

    private func fail(_ error: SFTPError) {
        guard failure == nil else { return }
        failure = error
        log.warning("sftp connection ended: \(error.localizedDescription)")
        versionWaiter?.resume(throwing: error)
        versionWaiter = nil
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: error) }
        transport.close()
    }

    private func expectOK(_ response: SFTPResponse) throws {
        switch response {
        case .status(.ok, _): return
        case .status(let code, let message): throw SFTPError.status(code, message)
        default: throw SFTPError.unexpectedResponse
        }
    }

    private func handle(from response: SFTPResponse) throws -> Data {
        switch response {
        case .handle(let handle): return handle
        case .status(let code, let message): throw SFTPError.status(code, message)
        default: throw SFTPError.unexpectedResponse
        }
    }

    private func attributes(from response: SFTPResponse) throws -> SFTPAttributes {
        switch response {
        case .attributes(let attributes): return attributes
        case .status(let code, let message): throw SFTPError.status(code, message)
        default: throw SFTPError.unexpectedResponse
        }
    }
}
