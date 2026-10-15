import Foundation
import Observation

/// The live, observable copy of `settings.json`.
///
/// Every change is saved (debounced) and published to observers, so the Control Center,
/// open terminals and services all react to one source of truth. Edits made to the file
/// outside Harbor are picked up and applied too.
@MainActor
@Observable
public final class SettingsStore {
    public var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            scheduleSave()
        }
    }

    /// Set when the file on disk could not be read and was moved aside.
    public private(set) var loadIssue: String?

    @ObservationIgnored private let store: JSONFileStore<AppSettings>
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored public var onSaveError: (@MainActor (Error) -> Void)?

    public init(store: JSONFileStore<AppSettings>) {
        self.store = store
        let result = store.load()
        settings = result.value
        if let corrupt = result.recoveredFrom {
            loadIssue = "settings.json could not be read (\(corrupt.error)). A copy was saved to \(corrupt.backupURL.lastPathComponent) and defaults were restored."
        }
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
    }

    /// Writes pending changes immediately (used at quit).
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        persist()
    }

    public func startWatchingForExternalChanges() {
        guard watcher == nil else { return }
        let watcher = FileWatcher(url: store.url) { [weak self] in
            Task { @MainActor in self?.reloadFromDisk() }
        }
        watcher.start()
        self.watcher = watcher
    }

    private func reloadFromDisk() {
        let loaded = store.load()
        guard loaded.recoveredFrom == nil, loaded.value != settings else { return }
        settings = loaded.value
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func persist() {
        do {
            try store.save(settings)
        } catch {
            onSaveError?(error)
        }
    }
}
