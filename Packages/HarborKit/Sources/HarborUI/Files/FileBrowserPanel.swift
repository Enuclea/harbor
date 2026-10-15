import HarborFiles
import SwiftUI

/// The flyout chrome: location, breadcrumbs, the file list and active transfers.
struct FileBrowserPanel: View {
    @Bindable var model: FileBrowserModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            breadcrumbs
            Divider().opacity(0.5)
            ZStack {
                FileTableView(model: model, onClose: onClose)
                    .opacity(model.error == nil ? 1 : 0.35)
                if let error = model.error {
                    errorView(error)
                } else if model.isLoading && model.entries.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxHeight: .infinity)
            TransferList(center: model.transfers)
            footer
        }
        .glassPanel(cornerRadius: 16)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(from: providers) { urls in Task { await model.upload(urls) } }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isRemote ? "server.rack" : "laptopcomputer")
                .foregroundStyle(.secondary)
            Text(model.title)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button { model.showHidden.toggle() } label: {
                Image(systemName: model.showHidden ? "eye" : "eye.slash")
            }
            .help(model.showHidden ? "Hide hidden files" : "Show hidden files")
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
            // No Escape shortcut here: it would apply window-wide and take Esc from vim.
            // The file list handles Escape while it has focus.
            Button(action: onClose) { Image(systemName: "xmark") }
                .help("Close (Esc in the file list)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button { Task { await model.goUp() } } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .help("Enclosing folder (⌘↑)")
                    .disabled(model.path == "/" || model.path.isEmpty)
                ForEach(Array(RemotePath.breadcrumbs(model.path).enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary).font(.caption)
                    }
                    Button(crumb.name == "/" ? "/" : crumb.name) { Task { await model.load(crumb.path) } }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .foregroundStyle(crumb.path == model.path ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center).font(.callout)
            if model.isRemote {
                Text("The file browser uses this tab's SSH connection. Sign in in the tab first, then retry.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("Retry") { Task { await model.refresh() } }
        }
        .padding(20)
        .glassPanel(cornerRadius: 12)
        .padding()
    }

    private var footer: some View {
        HStack {
            Toggle("Follow terminal", isOn: $model.followsTerminal)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
            Spacer()
            Button("cd here") { model.changeTerminalDirectory(to: model.path) }
                .controlSize(.small)
                .disabled(model.path.isEmpty || !model.canChangeTerminalDirectory)
                .help("Change the terminal's directory to this folder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func loadURLs(from providers: [NSItemProvider], completion: @escaping @Sendable ([URL]) -> Void) {
        let collector = URLCollector(expected: providers.count, completion: completion)
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in collector.add(url) }
        }
    }
}

/// Gathers asynchronously loaded drop URLs and reports them once.
private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var remaining: Int
    private let completion: @Sendable ([URL]) -> Void

    init(expected: Int, completion: @escaping @Sendable ([URL]) -> Void) {
        remaining = expected
        self.completion = completion
    }

    func add(_ url: URL?) {
        let done: [URL]? = lock.withLock {
            if let url { urls.append(url) }
            remaining -= 1
            return remaining == 0 ? urls : nil
        }
        if let done, !done.isEmpty { completion(done) }
    }
}

/// Active and recent transfers with progress.
struct TransferList: View {
    let center: TransferCenter

    var body: some View {
        if !center.transfers.isEmpty {
            VStack(spacing: 6) {
                HStack {
                    Text("Transfers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if center.transfers.contains(where: { !$0.isActive }) {
                        Button("Clear") { center.clearFinished() }.buttonStyle(.borderless).font(.caption)
                    }
                }
                ForEach(center.transfers.prefix(5)) { transfer in
                    TransferRow(transfer: transfer) { center.cancel(transfer) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.08))
        }
    }
}

private struct TransferRow: View {
    let transfer: Transfer
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: transfer.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.name).font(.caption).lineLimit(1).truncationMode(.middle)
                switch transfer.state {
                case .running, .queued:
                    if let fraction = transfer.fraction {
                        ProgressView(value: fraction).controlSize(.mini)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.mini)
                    }
                case .finished:
                    Text(ByteCountFormatter.string(fromByteCount: transfer.completed, countStyle: .file))
                        .font(.caption2).foregroundStyle(.secondary)
                case .cancelled:
                    Text("Cancelled").font(.caption2).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if transfer.isActive {
                Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            } else if let url = transfer.resultURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
        }
    }
}
