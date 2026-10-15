import Foundation
@testable import HarborFiles
import HarborSSH
import Testing

/// These tests speak SFTP to the real OpenSSH server binary that ships with macOS,
/// so the client is verified against the implementation it will meet in production.
private func makeBrowser() -> RemoteFileBrowser {
    RemoteFileBrowser(title: "local sftp-server") {
        try ProcessSFTPTransport(command: CommandSpec("/usr/libexec/sftp-server", []))
    }
}

private func makeSandbox() throws -> URL {
    signal(SIGPIPE, SIG_IGN)
    let url = FileManager.default.temporaryDirectory.appending(path: "harbor-sftp-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("SFTP client against /usr/libexec/sftp-server")
struct SFTPClientTests {
    @Test func listsDirectoriesWithAttributes() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "folder"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appending(path: "hello.txt"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: root.appending(path: "folder"))

        let browser = makeBrowser()
        let entries = try await browser.list(root.path).sorted(by: FileEntry.finderOrder)
        #expect(entries.map(\.name) == ["folder", "hello.txt", "link"])
        #expect(entries[0].kind == .directory)
        #expect(entries[1].size == 5)
        #expect(entries[2].kind == .symlink)
        #expect(try await browser.resolve(entries[2]).kind == .directory)
        #expect(!(try await browser.homeDirectory()).isEmpty)
    }

    @Test func roundTripsLargeFilesByteForByte() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        // 5 MiB + 123 bytes: many pipelined chunks and a ragged final chunk.
        var bytes = [UInt8](repeating: 0, count: 5 * 1024 * 1024 + 123)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 2_654_435_761 >> 7) }
        let original = Data(bytes)
        let source = root.appending(path: "source.bin")
        try original.write(to: source)
        let remoteDirectory = root.appending(path: "remote")
        try FileManager.default.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)

        let browser = makeBrowser()
        let progressSeen = ProgressRecorder()
        try await browser.upload(source, into: remoteDirectory.path) { done, total in progressSeen.record(done, total) }
        let uploaded = try Data(contentsOf: remoteDirectory.appending(path: "source.bin"))
        #expect(uploaded == original)
        #expect(progressSeen.last == Int64(original.count))

        let downloads = root.appending(path: "downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let entry = try #require(try await browser.list(remoteDirectory.path).first)
        let downloaded = try await browser.download(entry, into: downloads) { _, _ in }
        #expect(try Data(contentsOf: downloaded) == original)
    }

    @Test func copiesFoldersRecursivelyAndDeletesThem() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appending(path: "project")
        try FileManager.default.createDirectory(at: tree.appending(path: "src/deep"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: tree.appending(path: "README"))
        try Data("b".utf8).write(to: tree.appending(path: "src/deep/main.swift"))
        let remote = root.appending(path: "remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)

        let browser = makeBrowser()
        try await browser.upload(tree, into: remote.path) { _, _ in }
        #expect(FileManager.default.fileExists(atPath: remote.appending(path: "project/src/deep/main.swift").path))

        // Uploading again must not overwrite: it becomes "project 2".
        try await browser.upload(tree, into: remote.path) { _, _ in }
        #expect(FileManager.default.fileExists(atPath: remote.appending(path: "project 2/README").path))

        let entry = try #require(try await browser.list(remote.path).first { $0.name == "project" })
        try await browser.delete(entry)
        #expect(!FileManager.default.fileExists(atPath: remote.appending(path: "project").path))
    }

    @Test func renamesAndMakesDirectories() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let browser = makeBrowser()
        try await browser.makeDirectory(RemotePath.join(root.path, "new"))
        try await browser.rename(RemotePath.join(root.path, "new"), to: RemotePath.join(root.path, "renamed"))
        #expect(try await browser.list(root.path).map(\.name) == ["renamed"])
    }

    @Test func reportsMissingFilesClearly() async throws {
        let browser = makeBrowser()
        await #expect(throws: SFTPError.self) { _ = try await browser.list("/definitely/not/here") }
        // The connection survives the error.
        #expect(!(try await browser.homeDirectory()).isEmpty)
    }

    @Test func failedConnectionSurfacesReason() async throws {
        let browser = RemoteFileBrowser(title: "broken") {
            try ProcessSFTPTransport(command: CommandSpec("/bin/sh", ["-c", "echo 'Permission denied (publickey).' >&2; exit 255"]))
        }
        do {
            _ = try await browser.homeDirectory()
            Issue.record("expected failure")
        } catch {
            #expect(error.localizedDescription.contains("Permission denied"))
        }
    }
}

@Suite("Remote paths")
struct RemotePathTests {
    @Test func joinsAndSplits() {
        #expect(RemotePath.join("/home/dan", "a.txt") == "/home/dan/a.txt")
        #expect(RemotePath.join("/", "etc") == "/etc")
        #expect(RemotePath.parent(of: "/home/dan") == "/home")
        #expect(RemotePath.parent(of: "/home") == "/")
        #expect(RemotePath.lastComponent("/home/dan/") == "dan")
        #expect(RemotePath.breadcrumbs("/a/b").map(\.path) == ["/", "/a", "/a/b"])
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    func record(_ done: Int64, _ total: Int64?) { lock.withLock { value = max(value, done) } }
    var last: Int64 { lock.withLock { value } }
}
