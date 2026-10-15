import AppKit
import HarborCore
import HarborDoctor
import HarborMCP
import HarborSSH
import SwiftUI

/// First-run setup: prompt, hosts, AI assistants and a health check, in under a minute.
@MainActor
final class OnboardingWindowController: NSWindowController {
    init(services: AppServices, onFinish: @escaping () -> Void) {
        let model = OnboardingModel(services: services)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: OnboardingView(model: model) { [weak self] in
            self?.close()
            onFinish()
        })
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable {
        case welcome, prompt, hosts, assistants, health
    }

    var step: Step = .welcome
    var preset: PromptPreset = .harbor
    var scope: PromptScope = .harborSessions
    var hostCandidates: [SSHConfigEntry] = []
    var selectedHosts: Set<String> = []
    var assistantStatuses: [MCPClientStatus] = []
    var selectedAssistants: Set<MCPClientApp> = []
    var report: DoctorReport?

    let services: AppServices

    init(services: AppServices) {
        self.services = services
        let existing = Set(services.hosts.hosts.map(\.hostname))
        hostCandidates = SSHConfigParser.load(from: services.paths.sshConfig, sshDirectory: services.paths.sshDirectory)
            .filter { !existing.contains($0.alias) }
        selectedHosts = Set(hostCandidates.map(\.alias))
        if let current = PromptPreset.allCases.first(where: { $0.title == services.settings.settings.shell.prompt.presetName }) {
            preset = current
        }
        scope = services.settings.settings.shell.promptScope
    }

    func loadAssistants() async {
        assistantStatuses = await services.mcpRegistry.status()
        selectedAssistants = Set(assistantStatuses.filter { $0.isInstalled && !$0.isRegistered }.map(\.app))
    }

    func runHealthCheck() async {
        report = await services.doctor.run(await services.actionsDoctorContext())
    }

    /// Applies every choice. Called once, from the final step.
    func finish() async {
        services.settings.update {
            $0.shell.prompt = preset.config
            $0.shell.promptScope = scope
            $0.onboarding.completedVersion = OnboardingState.currentVersion
        }
        services.hosts.importHosts(hostCandidates.filter { selectedHosts.contains($0.alias) }.map { $0.makeHostProfile() })
        for app in selectedAssistants {
            try? await services.mcpRegistry.register(app)
        }
    }

    func advance() {
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }

    func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }
}

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    let done: () -> Void
    @State private var finishing = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome: welcome
                case .prompt: prompt
                case .hosts: hosts
                case .assistants: assistants
                case .health: health
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .padding(.top, 40)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))

            footer
        }
        .frame(width: 760, height: 560)
        .background(.background)
        .animation(.smooth(duration: 0.3), value: model.step)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "apple.terminal.on.rectangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("Welcome to Harbor").font(.largeTitle.bold())
            Text("Terminal, SSH hosts, file transfer and AI assistance — together, and native to your Mac.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 28) {
                feature("rectangle.stack", "Tabs for local and SSH sessions")
                feature("folder", "Drag files to and from servers")
                feature("sparkles", "Let AI assistants work in your tabs")
                feature("globe", "Reach it all from a browser")
            }
            .padding(.top, 12)
            Spacer()
        }
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint)
            Text(text).font(.callout).multilineTextAlignment(.center).frame(width: 130)
        }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Choose your prompt", "You can fine-tune segments and colours later in Settings ▸ Prompt.")
            PromptPreviewView(config: model.preset.config, theme: model.services.currentTheme, failed: false)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], spacing: 10) {
                ForEach(PromptPreset.allCases) { preset in
                    Button { model.preset = preset } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.title).font(.headline)
                            Text(preset.summary).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(model.preset == preset ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Picker("Use it in", selection: $model.scope) {
                ForEach(PromptScope.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var hosts: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Bring your hosts", model.hostCandidates.isEmpty
                ? "No hosts found in ~/.ssh/config. Add hosts any time from Settings ▸ Hosts or Quick Connect (⇧⌘K)."
                : "Harbor found these in ~/.ssh/config. Imported hosts keep using your config's options.")
            if !model.hostCandidates.isEmpty {
                List(model.hostCandidates, id: \.alias) { entry in
                    Toggle(isOn: Binding(
                        get: { model.selectedHosts.contains(entry.alias) },
                        set: { if $0 { model.selectedHosts.insert(entry.alias) } else { model.selectedHosts.remove(entry.alias) } })) {
                        VStack(alignment: .leading) {
                            Text(entry.alias)
                            Text(entry.resolvedDestination).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var assistants: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Connect your AI assistants", "Assistants can list tabs, read screens and run commands. By default they must ask you before typing anything.")
            ForEach(model.assistantStatuses, id: \.app) { status in
                Toggle(isOn: Binding(
                    get: { model.selectedAssistants.contains(status.app) || status.isRegistered },
                    set: { if $0 { model.selectedAssistants.insert(status.app) } else { model.selectedAssistants.remove(status.app) } })) {
                    HStack {
                        Text(status.app.displayName)
                        if status.isRegistered { StatusBadge(text: "Connected", tone: .good) }
                        if !status.isInstalled { StatusBadge(text: "Not installed", tone: .neutral) }
                    }
                }
                .disabled(!status.isInstalled || status.isRegistered)
            }
            Spacer()
        }
        .task { await model.loadAssistants() }
    }

    private var health: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader("Health check", "Harbor checked your setup. Fix anything flagged now, or later from Settings ▸ Diagnostics.")
            if let report = model.report {
                List(report.results) { result in
                    CheckRow(result: result) { remedy in
                        model.services.actions?.perform(remedy)
                        Task { await model.runHealthCheck() }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ProgressView("Checking…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await model.runHealthCheck() }
    }

    private func stepHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title.bold())
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                    Capsule().fill(step == model.step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: step == model.step ? 18 : 7, height: 7)
                }
            }
            Spacer()
            if model.step != .welcome {
                Button("Back") { model.back() }
            }
            if model.step == .health {
                Button(finishing ? "Setting up…" : "Start Using Harbor") {
                    finishing = true
                    Task {
                        await model.finish()
                        done()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(finishing)
            } else {
                Button(model.step == .welcome ? "Get Started" : "Continue") { model.advance() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
    }
}
