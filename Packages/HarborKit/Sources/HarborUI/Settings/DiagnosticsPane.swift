import HarborDoctor
import SwiftUI

struct DiagnosticsPane: View {
    let services: AppServices
    @State private var report: DoctorReport?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                summaryIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(summaryTitle).font(.title3.weight(.semibold))
                    Text("Checks run on this Mac only. Nothing is sent anywhere.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(running ? "Checking…" : "Check Again") { Task { await run() } }.disabled(running)
            }
            .padding(20)

            List(report?.results ?? []) { result in
                CheckRow(result: result) { remedy in
                    services.actions?.perform(remedy)
                    Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        await run()
                    }
                }
            }
        }
        .task { await run() }
    }

    private var summaryTitle: String {
        guard let report else { return "Checking Harbor's health…" }
        switch report.worstStatus {
        case .pass, .info: return "Everything looks good"
        case .warning: return "\(report.problems.count) thing\(report.problems.count == 1 ? "" : "s") to look at"
        case .failure: return "\(report.problems.count) problem\(report.problems.count == 1 ? "" : "s") found"
        }
    }

    @ViewBuilder
    private var summaryIcon: some View {
        if running || report == nil {
            ProgressView()
        } else {
            CheckStatusIcon(status: report?.worstStatus ?? .pass).font(.largeTitle)
        }
    }

    private func run() async {
        running = true
        let context = await services.actionsDoctorContext()
        report = await services.doctor.run(context)
        running = false
    }
}

struct CheckStatusIcon: View {
    let status: CheckStatus

    var body: some View {
        switch status {
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(.blue)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failure: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

struct CheckRow: View {
    let result: CheckResult
    let perform: (Remedy) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CheckStatusIcon(status: result.status).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title).font(.body.weight(.medium))
                Text(result.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let detail = result.detail {
                    Text(detail).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let remedy = result.remedy {
                Button(remedy.title) { perform(remedy) }
            }
        }
        .padding(.vertical, 6)
    }
}
