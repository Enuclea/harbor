import Foundation
import HarborCore
import HarborLogging

/// Packs everything needed to troubleshoot into one zip: the diagnostics report, redacted
/// logs, the (secret-free) settings file and system facts. Nothing is sent anywhere.
public struct SupportBundle: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func create(report: DoctorReport, destinationDirectory: URL) async throws -> URL {
        let stamp = report.date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let work = FileManager.default.temporaryDirectory.appending(path: "Harbor Support \(stamp)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        try report.markdown.write(to: work.appending(path: "diagnostics.md"), atomically: true, encoding: .utf8)
        try await systemInfo().write(to: work.appending(path: "system.txt"), atomically: true, encoding: .utf8)

        if let settings = try? String(contentsOf: paths.settingsFile, encoding: .utf8) {
            try Redactor.redact(settings).write(to: work.appending(path: "settings.json"), atomically: true, encoding: .utf8)
        }
        let logDirectory = work.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logFiles = ((try? FileManager.default.contentsOfDirectory(at: paths.logs, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
        for file in logFiles {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            try Redactor.redact(text).write(to: logDirectory.appending(path: file.lastPathComponent), atomically: true, encoding: .utf8)
        }

        let archive = destinationDirectory.appending(path: "Harbor Support \(stamp).zip")
        try? FileManager.default.removeItem(at: archive)
        let zip = try await ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", work.path, archive.path], timeout: .seconds(60))
        guard zip.succeeded else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Couldn't create the archive: \(zip.errorOutput)"])
        }
        Log(.doctor).notice("support bundle written to \(archive.path)")
        return archive
    }

    private func systemInfo() async -> String {
        let info = ProcessInfo.processInfo
        var lines = [
            "\(AppIdentity.name) \(AppIdentity.version) (\(AppIdentity.build))",
            "macOS \(info.operatingSystemVersionString)",
            "Hardware: \(Self.machine())",
            "Memory: \(info.physicalMemory / 1_073_741_824) GB",
            "Locale: \(Locale.current.identifier)",
        ]
        if let shell = try? await ProcessRunner.run("/bin/zsh", ["--version"], timeout: .seconds(5)) {
            lines.append("zsh: \(shell.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let ssh = try? await ProcessRunner.run("/usr/bin/ssh", ["-V"], timeout: .seconds(5)) {
            lines.append("ssh: \(ssh.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func machine() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
