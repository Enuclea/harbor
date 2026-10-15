import Foundation

/// Watches a single file for external edits (e.g. the user editing `settings.json` in
/// their editor). Handles atomic-save editors that replace the file by re-arming on rename/delete.
public final class FileWatcher: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "harbor.file-watcher")
    private let onChange: @Sendable () -> Void
    private var source: DispatchSourceFileSystemObject?

    public init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    public func start() {
        queue.async { self.arm() }
    }

    public func stop() {
        queue.async {
            self.source?.cancel()
            self.source = nil
        }
    }

    private func arm() {
        source?.cancel()
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // File not there yet; try again shortly.
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.arm() }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            self.onChange()
            if events.contains(.rename) || events.contains(.delete) {
                self.queue.asyncAfter(deadline: .now() + 0.2) { self.arm() }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}
