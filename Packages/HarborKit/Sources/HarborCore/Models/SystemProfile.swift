import Darwin
import Foundation

/// Structured system and environment metadata (`uname`, OS distribution, package manager,
/// available CLI tools, and repository state) attached to a terminal session and serialized
/// as JSON to give AI assistants accurate system context when generating commands.
public struct SystemProfile: Codable, Sendable, Equatable {
    public var os: String
    public var kernel: String?
    public var arch: String
    public var distro: String?
    public var hostname: String?
    public var user: String?
    public var isRoot: Bool?
    public var shell: String?
    public var packageManager: String?
    public var initSystem: String?
    public var tools: [String]?
    public var cwd: String?
    public var gitState: String?

    public init(
        os: String,
        kernel: String? = nil,
        arch: String,
        distro: String? = nil,
        hostname: String? = nil,
        user: String? = nil,
        isRoot: Bool? = nil,
        shell: String? = nil,
        packageManager: String? = nil,
        initSystem: String? = nil,
        tools: [String]? = nil,
        cwd: String? = nil,
        gitState: String? = nil
    ) {
        self.os = os
        self.kernel = kernel
        self.arch = arch
        self.distro = distro
        self.hostname = hostname
        self.user = user
        self.isRoot = isRoot
        self.shell = shell
        self.packageManager = packageManager
        self.initSystem = initSystem
        self.tools = tools
        self.cwd = cwd
        self.gitState = gitState
    }

    /// Short human-readable summary for the `⌘I` Command Assist bar badge.
    public var badgeSummary: String {
        var parts: [String] = []
        if let distro, !distro.isEmpty {
            parts.append(distro)
        } else {
            parts.append(os)
        }
        parts.append(arch)
        if let packageManager, !packageManager.isEmpty {
            parts.append(packageManager)
        } else if let shell, !shell.isEmpty {
            parts.append((shell as NSString).lastPathComponent)
        }
        return parts.joined(separator: " · ")
    }

    /// Produces a compact single-line JSON string suitable for feeding into an LLM prompt.
    public func compactJSON(cwd overrideCwd: String? = nil, gitState overrideGit: String? = nil) -> String {
        var copy = self
        if let overrideCwd { copy.cwd = overrideCwd }
        if let overrideGit { copy.gitState = overrideGit }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(copy),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"os\":\"\(os)\",\"arch\":\"\(arch)\"}"
        }
        return json
    }

    /// Decodes a `SystemProfile` from a raw JSON string (or URL-percent-encoded JSON string).
    public static func decode(from raw: String) -> SystemProfile? {
        let candidate = raw.removingPercentEncoding ?? raw
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else { return nil }
        let slice = String(trimmed[start...end])
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SystemProfile.self, from: data)
    }

    /// Builds an instant `SystemProfile` for the local Mac without spawning child processes.
    public static func currentLocal(shell: String? = nil, cwd: String? = nil) -> SystemProfile {
        var sys = utsname()
        uname(&sys)
        let sysname = withUnsafePointer(to: &sys.sysname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        let release = withUnsafePointer(to: &sys.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        let machine = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        let distro = "macOS \(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"
        let probeTools = ["git", "brew", "docker", "rg", "jq", "tmux", "python3", "swift", "gh"]
        let installedTools = probeTools.filter { ExecutableLocator.find($0) != nil }
        let pkg = ExecutableLocator.find("brew") != nil ? "brew" : nil

        return SystemProfile(
            os: sysname.isEmpty ? "Darwin" : sysname,
            kernel: release.isEmpty ? nil : release,
            arch: machine.isEmpty ? "arm64" : machine,
            distro: distro,
            hostname: ProcessInfo.processInfo.hostName,
            user: NSUserName(),
            isRoot: geteuid() == 0,
            shell: shell ?? (ProcessInfo.processInfo.environment["SHELL"] as NSString?)?.lastPathComponent ?? "zsh",
            packageManager: pkg,
            initSystem: "launchd",
            tools: installedTools,
            cwd: cwd
        )
    }

    /// POSIX-compatible one-liner that gathers `uname`, OS release, package manager, init system,
    /// available tools, and git repository status as a single-line JSON object.
    public static let remoteProbeCommand: String = #"""
    sh -c '
    _esc() { printf "%s" "$1" | tr -d "\n\r\"\\" ; }
    os=$(_esc "$(uname -s 2>/dev/null)")
    kern=$(_esc "$(uname -r 2>/dev/null)")
    arch=$(_esc "$(uname -m 2>/dev/null)")
    host=$(_esc "$(uname -n 2>/dev/null)")
    usr=$(_esc "$(id -un 2>/dev/null || whoami 2>/dev/null)")
    uid=$(id -u 2>/dev/null || echo 1000)
     is_root="false"; [ "$uid" = "0" ] && is_root="true"
    sh_name=$(_esc "${SHELL##*/}")
    distro=""
    if [ -r /etc/os-release ]; then
      distro=$(_esc "$(. /etc/os-release 2>/dev/null && printf "%s" "${PRETTY_NAME:-$NAME $VERSION_ID}")")
    elif command -v sw_vers >/dev/null 2>&1; then
      distro=$(_esc "macOS $(sw_vers -productVersion 2>/dev/null)")
    fi
    pkg=""
    for p in apt dnf yum apk pacman zypper brew; do
      if command -v "$p" >/dev/null 2>&1; then pkg="$p"; break; fi
    done
    init=""
    if command -v systemctl >/dev/null 2>&1; then init="systemd"
    elif [ "$os" = "Darwin" ]; then init="launchd"
    elif command -v rc-service >/dev/null 2>&1; then init="openrc"
    fi
    tools=""
    for t in git docker podman systemctl journalctl tmux jq rg grep curl python3; do
      if command -v "$t" >/dev/null 2>&1; then
        tools="${tools:+$tools,}\"$t\""
      fi
    done
    cwd=$(_esc "$(pwd 2>/dev/null)")
    git_state="none"
    if command -v git >/dev/null 2>&1; then
      gout=$(git status --porcelain 2>&1)
      gcode=$?
      if [ $gcode -eq 0 ]; then
        if [ -z "$gout" ]; then git_state="clean"; else git_state="dirty"; fi
      elif printf "%s" "$gout" | grep -qi "dubious ownership"; then
        git_state="untrusted-safe-directory"
      fi
    fi
    printf "{\"os\":\"%s\",\"kernel\":\"%s\",\"arch\":\"%s\",\"distro\":\"%s\",\"hostname\":\"%s\",\"user\":\"%s\",\"isRoot\":%s,\"shell\":\"%s\",\"packageManager\":\"%s\",\"initSystem\":\"%s\",\"tools\":[%s],\"cwd\":\"%s\",\"gitState\":\"%s\"}\n" \
      "$os" "$kern" "$arch" "$distro" "$host" "$usr" "$is_root" "$sh_name" "$pkg" "$init" "$tools" "$cwd" "$git_state"
    '
    """#
}
