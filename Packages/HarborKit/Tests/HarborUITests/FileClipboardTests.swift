import AppKit
import HarborCore
import HarborFiles
import HarborSSH
@testable import HarborUI
import Testing

/// Copy on one host, paste on another — through a private pasteboard and a real
/// sftp-server standing in for the hosts.
@Suite("File clipboard", .serialized)
@MainActor
struct FileClipboardTests {
    private let root: URL
    private let remoteHome: URL
    private let clipboardFolder: URL
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("harbor-test-\(UUID().uuidString)"))
    private let browser: RemoteFileBrowser

    init() throws {
        signal(SIGPIPE, SIG_IGN)
        root = FileManager.default.temporaryDirectory.appending(path: "harbor-clipboard-\(UUID().uuidString)").resolvingSymlinksInPath()
        remoteHome = root.appending(path: "remote")
        clipboardFolder = root.appending(path: "clipboard")
        try FileManager.default.createDirectory(at: remoteHome.appending(path: "logs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remoteHome.appending(path: "dest"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clipboardFolder, withIntermediateDirectories: true)
        try "hello".write(to: remoteHome.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        try "line".write(to: remoteHome.appending(path: "logs/app.log"), atomically: true, encoding: .utf8)
        let home = remoteHome.path
        browser = RemoteFileBrowser(title: "nexus") {
            try ProcessSFTPTransport(command: CommandSpec("/usr/libexec/sftp-server", ["-d", home]))
        }
    }

    private func clipboard() -> FileClipboard {
        FileClipboard(directory: clipboardFolder, transfers: TransferCenter(), pasteboard: pasteboard)
    }

    private func entries(_ names: Set<String>) async throws -> [FileEntry] {
        try await browser.list(remoteHome.path).filter { names.contains($0.name) }.sorted { $0.name < $1.name }
    }

    private func cleanUp() async {
        await browser.disconnect()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    @Test func copiesAFileAndAFolderFromOneHostAndPastesOnAnother() async throws {
        let clipboard = clipboard()
        clipboard.copy(try await entries(["notes.txt", "logs"]), from: browser)
        #expect(clipboard.contents?.summary == "Copying 2 items from nexus…")

        let urls = await clipboard.itemsToPaste()
        #expect(urls.map(\.lastPathComponent).sorted() == ["logs", "notes.txt"])
        #expect(clipboard.contents?.summary == "2 items from nexus")
        #expect(urls.allSatisfy { $0.path.hasPrefix(clipboardFolder.path) }, "held on this Mac, independent of the source tab")
        #expect(pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.count == 2,
                "Finder can paste them too")

        // "Another host": upload into a different folder, twice (the second gets new names).
        for _ in 0..<2 {
            for url in urls { try await browser.upload(url, into: remoteHome.appending(path: "dest").path) { _, _ in } }
        }
        let dest = remoteHome.appending(path: "dest")
        #expect(try String(contentsOf: dest.appending(path: "notes.txt"), encoding: .utf8) == "hello")
        #expect(try String(contentsOf: dest.appending(path: "logs/app.log"), encoding: .utf8) == "line")
        #expect(FileManager.default.fileExists(atPath: dest.appending(path: "notes 2.txt").path), "pasting again never overwrites")
        await cleanUp()
    }

    @Test func survivesARestart() async throws {
        let first = clipboard()
        first.copy(try await entries(["notes.txt"]), from: browser)
        let copied = await first.itemsToPaste()

        let afterRestart = clipboard()
        #expect(afterRestart.contents?.names == ["notes.txt"])
        #expect(await afterRestart.itemsToPaste() == copied)
        #expect(FileManager.default.fileExists(atPath: copied[0].path), "the held copy isn't pruned while it's on the pasteboard")
        await cleanUp()
    }

    @Test func aNewCopyReplacesTheHeldFiles() async throws {
        let clipboard = clipboard()
        clipboard.copy(try await entries(["notes.txt"]), from: browser)
        let old = await clipboard.itemsToPaste()
        clipboard.copy(try await entries(["logs"]), from: browser)
        let new = await clipboard.itemsToPaste()
        #expect(new.map(\.lastPathComponent) == ["logs"])
        #expect(!FileManager.default.fileExists(atPath: old[0].deletingLastPathComponent().path))
        await cleanUp()
    }

    @Test func pastesFilesCopiedInFinder() async throws {
        let file = root.appending(path: "from-finder.txt")
        try "finder".write(to: file, atomically: true, encoding: .utf8)
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])

        let clipboard = clipboard()
        #expect(clipboard.canPaste)
        #expect(await clipboard.itemsToPaste() == [file])
        await cleanUp()
    }

    @Test func localItemsAreReferencedInPlace() async throws {
        let local = LocalFileBrowser()
        let clipboard = clipboard()
        let entry = try await local.list(remoteHome.path).first { $0.name == "notes.txt" }
        clipboard.copy([try #require(entry)], from: local)
        let pasted = await clipboard.itemsToPaste()
        #expect(pasted.map(\.standardizedFileURL.path) == [remoteHome.appending(path: "notes.txt").path], "\(pasted)")
        #expect((try FileManager.default.contentsOfDirectory(atPath: clipboardFolder.path)).isEmpty)
        await cleanUp()
    }
}
