import Darwin
import Foundation
import HarborLogging

public enum UnixSocketError: Error, LocalizedError {
    case pathTooLong(String)
    case alreadyInUse(String)
    case system(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path): "Socket path is too long: \(path)"
        case .alreadyInUse(let path): "Another copy of Harbor is already serving \(path)."
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// A newline-delimited stream connection accepted by `UnixSocketServer`.
public final class UnixSocketConnection: @unchecked Sendable {
    public let peerPID: pid_t
    private let descriptor: Int32
    private let readQueue = DispatchQueue(label: "harbor.socket.read")
    private let writeQueue = DispatchQueue(label: "harbor.socket.write")
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var inputEnded = false
    private let maximumLine = 16 * 1024 * 1024

    var onLine: (@Sendable (Data) -> Void)?
    /// The peer stopped sending (EOF or error). Responses may still be written; call
    /// `close()` once they have been.
    var onInputEnded: (@Sendable () -> Void)?

    init(descriptor: Int32, peerPID: pid_t) {
        self.descriptor = descriptor
        self.peerPID = peerPID
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: readQueue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        self.source = source
        source.resume()
    }

    /// Sends one line (a trailing newline is added if missing).
    public func send(_ line: Data) {
        var framed = line
        if framed.last != 0x0A { framed.append(0x0A) }
        let data = framed
        writeQueue.async { [self] in
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                    if written > 0 { offset += written } else if errno != EINTR { return }
                }
            }
        }
    }

    /// Closes the connection after any queued writes have gone out.
    public func close() {
        readQueue.async { [self] in
            stopReading()
            writeQueue.async { [descriptor] in Darwin.close(descriptor) }
        }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = read(descriptor, &chunk, chunk.count)
        guard count > 0 else {
            if count == 0 || (errno != EAGAIN && errno != EINTR) { stopReading() }
            return
        }
        buffer.append(contentsOf: chunk[0..<count])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { onLine?(Data(line)) }
        }
        if buffer.count > maximumLine { stopReading() }
    }

    private func stopReading() {
        guard !inputEnded else { return }
        inputEnded = true
        source?.cancel()
        source = nil
        onInputEnded?()
    }
}

/// Listens on a Unix domain socket that only the current user can reach: the directory
/// is `0700`, the socket `0600`, and every peer's uid is checked with `getpeereid`.
public final class UnixSocketServer: @unchecked Sendable {
    public let path: String
    private let queue = DispatchQueue(label: "harbor.socket.accept")
    private let onConnection: @Sendable (UnixSocketConnection) -> Void
    private let log = Log(.mcp)
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String, onConnection: @escaping @Sendable (UnixSocketConnection) -> Void) {
        self.path = path
        self.onConnection = onConnection
    }

    public func start() throws {
        guard path.utf8.count < 104 else { throw UnixSocketError.pathTooLong(path) }
        if Self.isServing(path) { throw UnixSocketError.alreadyInUse(path) }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.system("socket", errno) }
        var address = Self.address(for: path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.system("listen", code)
        }
        descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { [path] in
            Darwin.close(fd)
            unlink(path)
        }
        self.source = source
        source.resume()
        log.info("listening on \(path)")
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    private func acceptConnection() {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
            log.warning("rejected socket peer with uid \(uid)")
            Darwin.close(client)
            return
        }
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var pid: pid_t = 0
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength)
        let connection = UnixSocketConnection(descriptor: client, peerPID: pid)
        onConnection(connection)
        connection.start()
    }

    /// True when something is accepting connections at `path`.
    public static func isServing(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = address(for: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return result == 0
    }

    static func address(for path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}
