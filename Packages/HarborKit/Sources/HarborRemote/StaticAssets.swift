import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Serves the bundled browser dashboard. Files are read once and kept in memory;
/// only names on the allowlist can be requested, so there is no path traversal surface.
struct StaticAssets: Sendable {
    private let files: [String: (data: Data, contentType: String)]

    init() {
        var files: [String: (Data, String)] = [:]
        if let root = Bundle.module.url(forResource: "web", withExtension: nil) {
            let names = ["index.html", "app.js", "app.css", "icon.svg", "vendor/xterm.js", "vendor/xterm.css", "vendor/addon-fit.js"]
            for name in names {
                if let data = try? Data(contentsOf: root.appending(path: name)) {
                    files[name] = (data, Self.contentType(for: name))
                }
            }
        }
        self.files = files
    }

    var isAvailable: Bool { files["index.html"] != nil }

    func register<Context: RequestContext>(on router: Router<Context>) {
        router.get("/") { _, _ in response(for: "index.html") }
        router.get("/index.html") { _, _ in response(for: "index.html") }
        router.get("/assets/**") { request, _ in
            let name = String(request.uri.path.dropFirst("/assets/".count))
            return response(for: name)
        }
    }

    private func response(for name: String) -> Response {
        guard let file = files[name] else { return Response(status: .notFound) }
        var headers: HTTPFields = [.contentType: file.contentType]
        // HTML must always be revalidated; versioned assets can be cached briefly.
        headers[.cacheControl] = name.hasSuffix(".html") ? "no-store" : "private, max-age=300"
        return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: file.data)))
    }

    private static func contentType(for name: String) -> String {
        switch (name as NSString).pathExtension {
        case "html": "text/html; charset=utf-8"
        case "js": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "svg": "image/svg+xml"
        default: "application/octet-stream"
        }
    }
}
