import AppKit
import HarborCore
import HarborDoctor
import HarborLogging
import SwiftUI

struct LogsPane: View {
    @Bindable var store: SettingsStore
    let feed: LogFeed
    let services: AppServices
    @State private var query = ""
    @State private var minimumLevel: LogLevel = .info
    @State private var category: LogCategory?
    @State private var exporting = false
    @State private var status: String?

    private var filtered: [LogEntry] {
        feed.entries.reversed().filter { entry in
            entry.level >= minimumLevel
                && (category == nil || entry.category == category)
                && (query.isEmpty || entry.message.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Logging") {
                    Picker("Record", selection: $store.settings.logging.level) {
                        ForEach(LogLevel.allCases, id: \.self) { Text("\($0.label) and above").tag($0) }
                    }
                    Stepper(value: $store.settings.logging.retentionDays, in: 1...365) {
                        LabeledContent("Keep logs for", value: "\(store.settings.logging.retentionDays) days")
                    }
                    Picker("Record session output", selection: $store.settings.logging.sessionRecording) {
                        ForEach(SessionRecordingMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Footnote("Session recordings capture what tabs display (never keystrokes) into ~/Library/Logs/Harbor/Sessions. They may contain sensitive output.")
                    HStack {
                        Button("Show Logs") { NSWorkspace.shared.open(services.paths.logs) }
                        Button("Show Recordings") { NSWorkspace.shared.open(services.paths.sessionRecordings) }
                        Button("Open in Console") { openConsole() }
                        Spacer()
                        if exporting { ProgressView().controlSize(.small) }
                        Button("Export Support Bundle…") { Task { await exportBundle() } }.disabled(exporting)
                    }
                    if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 300)

            HStack {
                TextField("Filter", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Picker("Level", selection: $minimumLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(width: 140)
                Picker("Category", selection: $category) {
                    Text("All").tag(LogCategory?.none)
                    ForEach(LogCategory.allCases, id: \.self) { Text($0.rawValue).tag(LogCategory?.some($0)) }
                }
                .frame(width: 160)
                Spacer()
                Button("Clear") { feed.clear() }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            List(filtered.prefix(1_000)) { entry in
                LogRow(entry: entry)
            }
            .listStyle(.plain)
        }
    }

    private func openConsole() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") {
            NSWorkspace.shared.open(url)
        }
    }

    private func exportBundle() async {
        exporting = true
        defer { exporting = false }
        services.fileLog.flush()
        let context = await services.actionsDoctorContext()
        let report = await services.doctor.run(context)
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? services.paths.home
        do {
            let archive = try await SupportBundle(paths: services.paths).create(report: report, destinationDirectory: desktop)
            status = "Saved \(archive.lastPathComponent) to your Desktop."
            NSWorkspace.shared.activateFileViewerSelecting([archive])
        } catch {
            status = error.localizedDescription
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date, format: .dateTime.hour().minute().second())
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .leading)
            Text(entry.level.rawValue.uppercased())
                .foregroundStyle(color)
                .frame(width: 58, alignment: .leading)
            Text(entry.category.rawValue)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(entry.message + (entry.metadata.isEmpty ? "" : "  " + entry.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")))
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var color: Color {
        switch entry.level {
        case .debug: .secondary
        case .info: .primary
        case .notice: .blue
        case .warning: .orange
        case .error, .fault: .red
        }
    }
}
