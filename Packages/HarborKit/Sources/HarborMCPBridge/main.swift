// harbor-mcp — stdio bridge between an MCP client (Claude Desktop, Claude Code, Cursor…)
// and the running Harbor app.
//
// It is deliberately dumb: bytes from stdin go to Harbor's control socket and bytes from
// the socket go to stdout. All MCP logic lives in the app, so the bridge can never drift
// out of sync with it. If Harbor isn't running, the bridge launches it in the background.

import Darwin
import Foundation
import HarborCore

signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--version") {
    print("harbor-mcp \(AppIdentity.version)")
    exit(0)
}
if arguments.contains("--help") || arguments.contains("-h") {
    print("""
        Usage: harbor-mcp [--socket PATH]

        Connects an MCP client to Harbor over stdio. Add it to your client's config:
          { "mcpServers": { "harbor": { "command": "\(CommandLine.arguments[0])" } } }
        """)
    exit(0)
}

let socketPath: String = {
    if let index = arguments.firstIndex(of: "--socket"), arguments.indices.contains(index + 1) { return arguments[index + 1] }
    return AppPaths.standard.controlSocket.path
}()

func log(_ message: String) {
    FileHandle.standardError.write(Data("harbor-mcp: \(message)\n".utf8))
}

func connectSocket(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        let bytes = Array(path.utf8.prefix(raw.count - 1))
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else {
        close(fd)
        return nil
    }
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

/// The Harbor.app this bridge lives in (Contents/MacOS/harbor-mcp → Harbor.app).
func enclosingApp() -> URL? {
    var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    while url.path != "/" {
        if url.pathExtension == "app" { return url }
        url.deleteLastPathComponent()
    }
    return nil
}

func launchHarbor() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let app = enclosingApp() {
        process.arguments = ["-g", "-j", app.path]
    } else {
        process.arguments = ["-g", "-j", "-b", AppIdentity.defaultBundleIdentifier]
    }
    try? process.run()
    process.waitUntilExit()
}

func connectOrLaunch() -> Int32? {
    if let fd = connectSocket(socketPath) { return fd }
    log("Harbor isn't running; launching it…")
    launchHarbor()
    for _ in 0..<60 {
        usleep(250_000)
        if let fd = connectSocket(socketPath) { return fd }
    }
    return nil
}

/// When Harbor can't be reached, answer each request with an error instead of hanging.
func serveUnavailable() -> Never {
    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] else { continue }
        let reply: [String: Any] = [
            "jsonrpc": "2.0", "id": id,
            "error": ["code": -32_000, "message": "Harbor is not running and could not be started. Open Harbor and try again."],
        ]
        if let encoded = try? JSONSerialization.data(withJSONObject: reply) {
            FileHandle.standardOutput.write(encoded + Data([0x0A]))
        }
    }
    exit(1)
}

guard let socket = connectOrLaunch() else {
    log("could not connect to \(socketPath)")
    serveUnavailable()
}

/// Copies bytes until EOF on `source`, then shuts down the write side of `destination`.
func pump(from source: Int32, to destination: Int32, onEnd: @escaping @Sendable () -> Void) -> Thread {
    let thread = Thread {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { write(destination, $0.baseAddress! + offset, count - offset) }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { onEnd(); return }
                offset += written
            }
        }
        onEnd()
    }
    thread.start()
    return thread
}

let finished = DispatchSemaphore(value: 0)
_ = pump(from: STDIN_FILENO, to: socket) {
    shutdown(socket, SHUT_WR)
}
_ = pump(from: socket, to: STDOUT_FILENO) {
    finished.signal()
}
finished.wait()
exit(0)
