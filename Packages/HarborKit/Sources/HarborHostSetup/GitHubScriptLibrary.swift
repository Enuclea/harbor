import Foundation
import HarborCore
import HarborFiles
import HarborLogging
import HarborSSH
import Observation

/// A runtime variable declared or referenced in a script playbook (`# @var:` / `# @secret:` / `${VAR:-default}`).
public struct ScriptVariable: Identifiable, Hashable, Sendable, Codable {
    public var id: String { name }
    public let name: String
    public let defaultValue: String
    public let summary: String
    public let isSecret: Bool

    public init(name: String, defaultValue: String = "", summary: String = "", isSecret: Bool = false) {
        self.name = name
        self.defaultValue = defaultValue
        self.summary = summary
        self.isSecret = isSecret
    }
}

/// A pre-canned script discovered in the synced GitHub repository.
public struct ScriptPlaybook: Identifiable, Hashable, Sendable, Codable {
    public var id: String { relativePath }
    public let relativePath: String
    public let name: String
    public let summary: String
    public let category: String
    public let requiresSudo: Bool
    public let interpreter: String
    public let fileURL: URL
    public let variables: [ScriptVariable]
    /// True when the entire file is marked `# @dnr` or `#dnr-file` (exclude completely from public repo splits).
    public let isFileDNR: Bool
    /// 1-indexed line numbers marked with `#dnr` (Do Not Release).
    public let dnrLineNumbers: [Int]
    /// Warnings if any line appears to contain a hardcoded secret or token instead of a variable.
    public let secretWarnings: [String]

    public var hasDNR: Bool { isFileDNR || !dnrLineNumbers.isEmpty }

    public init(
        relativePath: String,
        name: String,
        summary: String,
        category: String,
        requiresSudo: Bool,
        interpreter: String,
        fileURL: URL,
        variables: [ScriptVariable],
        isFileDNR: Bool,
        dnrLineNumbers: [Int],
        secretWarnings: [String]
    ) {
        self.relativePath = relativePath
        self.name = name
        self.summary = summary
        self.category = category
        self.requiresSudo = requiresSudo
        self.interpreter = interpreter
        self.fileURL = fileURL
        self.variables = variables
        self.isFileDNR = isFileDNR
        self.dnrLineNumbers = dnrLineNumbers
        self.secretWarnings = secretWarnings
    }

    public func loadContents() throws -> String {
        try String(contentsOf: fileURL, encoding: .utf8)
    }

    /// Parses script metadata headers, variables (`# @var:`, `# @secret:`, `${VAR:-default}`),
    /// `#dnr` (Do Not Release) markers, and potential hardcoded secret warnings.
    public static func parse(fileURL: URL, relativePath: String, contents: String) -> ScriptPlaybook {
        let lines = contents.components(separatedBy: .newlines)
        var parsedName: String?
        var parsedSummary: String?
        var parsedCategory: String?
        var requiresSudo = false
        var interpreter = defaultInterpreter(for: relativePath)
        var isFileDNR = false
        var dnrLineNumbers: [Int] = []
        var inDNRBlock = false
        var declaredVars: [String: ScriptVariable] = [:]
        var orderedVarNames: [String] = []
        var secretWarnings: [String] = []

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            if index == 0, trimmed.hasPrefix("#!") {
                interpreter = parseShebang(trimmed) ?? interpreter
            }

            // Detect #dnr (Do Not Release) file/block/line markers
            if lower.hasPrefix("# @dnr") || lower.hasPrefix("#@dnr") || lower.hasPrefix("#dnr-file") || lower.hasPrefix("# dnr-file") {
                isFileDNR = true
                dnrLineNumbers.append(lineNumber)
            } else if lower.contains("#dnr-start") || lower.contains("# dnr-start") {
                inDNRBlock = true
                dnrLineNumbers.append(lineNumber)
            } else if lower.contains("#dnr-end") || lower.contains("# dnr-end") {
                inDNRBlock = false
                dnrLineNumbers.append(lineNumber)
            } else if inDNRBlock || containsDNRMarker(lower) {
                dnrLineNumbers.append(lineNumber)
            }

            // Parse header tags in top comments
            if index < 45, trimmed.hasPrefix("#") {
                let comment = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if let value = extractTag("@name:", from: comment) ?? extractTag("title:", from: comment) {
                    parsedName = value
                } else if let value = extractTag("@description:", from: comment) ?? extractTag("description:", from: comment) {
                    parsedSummary = value
                } else if let value = extractTag("@category:", from: comment) ?? extractTag("category:", from: comment) {
                    parsedCategory = value
                } else if let value = extractTag("@sudo:", from: comment) {
                    requiresSudo = ["true", "yes", "1", "required"].contains(value.lowercased())
                } else if let spec = extractTag("@var:", from: comment) {
                    if let v = parseVariableSpec(spec, isSecret: false), declaredVars[v.name] == nil {
                        declaredVars[v.name] = v
                        orderedVarNames.append(v.name)
                    }
                } else if let spec = extractTag("@secret:", from: comment) {
                    if let v = parseVariableSpec(spec, isSecret: true), declaredVars[v.name] == nil {
                        declaredVars[v.name] = v
                        orderedVarNames.append(v.name)
                    }
                } else if parsedSummary == nil,
                          index > 0,
                          !comment.isEmpty,
                          !comment.hasPrefix("!"),
                          !comment.hasPrefix("@"),
                          !comment.lowercased().hasPrefix("dnr") {
                    parsedSummary = comment
                }
            }

            // Scan for `${VAR:-default}` or `${VAR}` references so nothing needs to be hardcoded
            for detected in extractShellParameterExpansions(from: rawLine) where declaredVars[detected.name] == nil {
                declaredVars[detected.name] = detected
                orderedVarNames.append(detected.name)
            }

            // Scan non-comment lines for accidental hardcoded secrets
            if !trimmed.hasPrefix("#"), let warning = detectHardcodedSecret(in: trimmed, lineNumber: lineNumber) {
                secretWarnings.append(warning)
            }
        }

        let pathParts = relativePath.split(separator: "/").map(String.init)
        let fallbackCategory = pathParts.count > 1 ? pathParts[0] : "general"
        let filename = pathParts.last ?? relativePath
        let fallbackName = humanizeFilename(filename)

        return ScriptPlaybook(
            relativePath: relativePath,
            name: parsedName ?? fallbackName,
            summary: parsedSummary ?? "Pre-canned \(fallbackCategory) script (\(relativePath))",
            category: parsedCategory ?? fallbackCategory,
            requiresSudo: requiresSudo,
            interpreter: interpreter,
            fileURL: fileURL,
            variables: orderedVarNames.compactMap { declaredVars[$0] },
            isFileDNR: isFileDNR,
            dnrLineNumbers: dnrLineNumbers,
            secretWarnings: secretWarnings
        )
    }

    /// Produces a public-safe version of a script by excluding `# @dnr` files (`nil`)
    /// and stripping any `#dnr` lines or `#dnr-start`…`#dnr-end` blocks.
    public static func sanitizeForPublicRelease(_ source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        var output: [String] = []
        var inDNRBlock = false

        for rawLine in lines {
            let lower = rawLine.trimmingCharacters(in: .whitespaces).lowercased()
            if lower.hasPrefix("# @dnr") || lower.hasPrefix("#@dnr") || lower.hasPrefix("#dnr-file") || lower.hasPrefix("# dnr-file") {
                return nil
            }
            if lower.contains("#dnr-start") || lower.contains("# dnr-start") {
                inDNRBlock = true
                continue
            }
            if lower.contains("#dnr-end") || lower.contains("# dnr-end") {
                inDNRBlock = false
                continue
            }
            if inDNRBlock || containsDNRMarker(lower) {
                continue
            }
            output.append(rawLine)
        }
        return output.joined(separator: "\n")
    }

    /// Builds the shell command string to run this script with parameterized environment variables.
    public static func buildCommand(
        scriptPath: String,
        interpreter: String,
        requiresSudo: Bool,
        variables: [ScriptVariable],
        values: [String: String],
        cleanupAfter: Bool = false
    ) -> String {
        var envAssignments: [String] = []
        for variable in variables {
            let rawVal = values[variable.name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let effective = rawVal.isEmpty ? variable.defaultValue : rawVal
            guard !effective.isEmpty else { continue }
            envAssignments.append("\(variable.name)=\(shellSingleQuote(effective))")
        }

        let envPrefix = envAssignments.isEmpty ? "" : envAssignments.joined(separator: " ") + " "
        let safeInterpreter = allowedInterpreters.contains(interpreter) ? interpreter : "sh"
        let quotedPath = shellSingleQuote(scriptPath)
        let runner: String
        if requiresSudo {
            runner = "sudo \(envPrefix)\(safeInterpreter) \(quotedPath)"
        } else {
            runner = "\(envPrefix)\(safeInterpreter) \(quotedPath)"
        }

        if cleanupAfter {
            return "\(runner); rm -f \(quotedPath)"
        }
        return runner
    }

    // MARK: Parsing Helpers

    private static func containsDNRMarker(_ lowerLine: String) -> Bool {
        guard let hashRange = lowerLine.range(of: "#") else { return false }
        let commentPart = lowerLine[hashRange.lowerBound...]
        return commentPart.contains("#dnr") || commentPart.contains("# dnr") || commentPart.contains("[dnr]")
    }

    private static func extractTag(_ tag: String, from comment: String) -> String? {
        guard comment.lowercased().hasPrefix(tag.lowercased()) else { return nil }
        let val = comment.dropFirst(tag.count).trimmingCharacters(in: .whitespaces)
        return val.isEmpty ? nil : val
    }

    /// Parses `VAR_NAME=default "Description"` or `VAR_NAME "Description"`.
    private static func parseVariableSpec(_ spec: String, isSecret: Bool) -> ScriptVariable? {
        var description = ""
        var head = spec
        if let firstQuote = spec.firstIndex(of: "\""),
           let lastQuote = spec.lastIndex(of: "\""),
           firstQuote != lastQuote {
            description = String(spec[spec.index(after: firstQuote)..<lastQuote])
            head = String(spec[..<firstQuote]).trimmingCharacters(in: .whitespaces)
        }
        let parts = head.split(separator: "=", maxSplits: 1).map(String.init)
        guard let rawName = parts.first?.trimmingCharacters(in: .whitespaces),
              isValidEnvName(rawName) else { return nil }
        let defaultVal = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return ScriptVariable(name: rawName, defaultValue: defaultVal, summary: description, isSecret: isSecret)
    }

    private static let ignoredShellVars: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "PWD", "OLDPWD", "IFS", "TERM",
        "HOSTNAME", "EUID", "UID", "RANDOM", "SECONDS", "LINENO", "SHLVL", "TMPDIR",
        "DEBIAN_FRONTEND", "LC_ALL", "LANG"
    ]

    /// Detects `${VAR:-default}` and `${VAR}` patterns in script lines.
    private static func extractShellParameterExpansions(from line: String) -> [ScriptVariable] {
        guard line.contains("${") else { return [] }
        var results: [ScriptVariable] = []
        var searchRange = line.startIndex..<line.endIndex
        while let open = line.range(of: "${", range: searchRange),
              let close = line.range(of: "}", range: open.upperBound..<line.endIndex) {
            let body = String(line[open.upperBound..<close.lowerBound])
            searchRange = close.upperBound..<line.endIndex

            let name: String
            let defaultVal: String
            if let fallbackRange = body.range(of: ":-") {
                name = String(body[..<fallbackRange.lowerBound])
                defaultVal = String(body[fallbackRange.upperBound...])
            } else if let assignRange = body.range(of: ":=") {
                name = String(body[..<assignRange.lowerBound])
                defaultVal = String(body[assignRange.upperBound...])
            } else {
                name = body
                defaultVal = ""
            }
            // Only treat ALL_CAPS identifiers as configurable environment parameters
            if isValidEnvName(name),
               name == name.uppercased(),
               name.count >= 3,
               !ignoredShellVars.contains(name) {
                results.append(ScriptVariable(name: name, defaultValue: defaultVal, summary: "Detected parameter ${\(body)}"))
            }
        }
        return results
    }

    private static func isValidEnvName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func detectHardcodedSecret(in line: String, lineNumber: Int) -> String? {
        if line.contains("BEGIN OPENSSH PRIVATE KEY") || line.contains("BEGIN RSA PRIVATE KEY") {
            return "Line \(lineNumber): Contains inline private key material"
        }
        let patterns = ["ghp_", "gho_", "github_pat_", "sk-ant-", "sk-proj-", "AKIA"]
        for token in patterns where line.contains(token) {
            return "Line \(lineNumber): Contains apparent token prefix '\(token)…' (use a @secret variable instead)"
        }
        return nil
    }

    private static let allowedInterpreters: Set<String> = [
        "sh", "bash", "zsh", "fish", "python3", "python"
    ]

    private static func parseShebang(_ line: String) -> String? {
        let stripped = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        let tokens = stripped.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return nil }
        let candidate: String
        if first.hasSuffix("/env"), tokens.count >= 2 {
            candidate = tokens[1]
        } else {
            candidate = (first as NSString).lastPathComponent
        }
        return allowedInterpreters.contains(candidate) ? candidate : nil
    }

    private static func defaultInterpreter(for path: String) -> String {
        let lower = path.lowercased()
        if lower.hasSuffix(".py") { return "python3" }
        if lower.hasSuffix(".zsh") { return "zsh" }
        if lower.hasSuffix(".fish") { return "fish" }
        if lower.hasSuffix(".bash") { return "bash" }
        return "sh"
    }

    private static func humanizeFilename(_ filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        return base
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                let lower = word.lowercased()
                if ["ssh", "ufw", "tls", "dns", "cpu", "os", "ip", "dnr"].contains(lower) {
                    return lower.uppercased()
                }
                return word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    public static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum GitHubScriptError: Error, LocalizedError {
    case missingRepositoryURL
    case missingDeployKey
    case invalidPrivateKey
    case gitFailed(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingRepositoryURL:
            "Enter a GitHub repository URL first (e.g. git@github.com:org/scripts.git)."
        case .missingDeployKey:
            "No read-only SSH deploy key is configured. Generate or paste a read-only deploy key first."
        case .invalidPrivateKey:
            "The provided text is not a valid OpenSSH private key."
        case .gitFailed(let detail):
            "Git operation failed: \(detail)"
        case .exportFailed(let detail):
            "Failed to export public-safe copy: \(detail)"
        }
    }
}

/// Manages the read-only GitHub script repository, deploy key lifecycle in Keychain,
/// `#dnr` (Do Not Release) auditing/splitting, and on-the-fly script execution.
@MainActor
@Observable
public final class GitHubScriptLibrary {
    public private(set) var scripts: [ScriptPlaybook] = []
    public private(set) var isSyncing = false
    public private(set) var statusMessage: String?
    public private(set) var errorMessage: String?
    /// In-memory session cache for `@secret` variables so secrets are never written to `settings.json`.
    public var sessionSecretValues: [String: String] = [:]

    private let paths: AppPaths
    private let settings: SettingsStore
    private let keychain: KeychainStore
    private let log = Log(.ssh)

    public init(paths: AppPaths, settings: SettingsStore, keychain: KeychainStore) {
        self.paths = paths
        self.settings = settings
        self.keychain = keychain
        reloadFromDisk()
    }

    // MARK: Deploy Key Management (Keychain-backed, Read-Only)

    public var hasKeychainDeployKey: Bool {
        (try? keychain.string(for: GitHubRepoSettings.keychainAccount))?.isEmpty == false
    }

    /// Generates a dedicated Ed25519 Read-Only Deploy Key, stores the private key in the macOS Keychain
    /// (never on disk in plaintext settings), and saves the public half for GitHub's Deploy Keys page.
    @discardableResult
    public func generateReadOnlyDeployKey() async throws -> String {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-deploy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDir.path)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let keyFile = tempDir.appendingPathComponent("id_ed25519_readonly")
        let comment = "harbor-readonly-deploy@\(Host.current().localizedName ?? "mac")"
        let result = try await ProcessRunner.run(
            "/usr/bin/ssh-keygen",
            ["-t", "ed25519", "-a", "100", "-N", "", "-C", comment, "-f", keyFile.path],
            timeout: .seconds(15)
        )
        guard result.succeeded,
              let privatePEM = try? String(contentsOf: keyFile, encoding: .utf8),
              let publicLine = try? String(contentsOfFile: keyFile.path + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw GitHubScriptError.gitFailed(result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        try keychain.set(privatePEM, for: GitHubRepoSettings.keychainAccount)
        settings.settings.github.keySource = .keychainDeployKey
        settings.settings.github.deployPublicKey = publicLine
        statusMessage = "Generated new Ed25519 read-only deploy key (stored in Keychain)."
        errorMessage = nil
        return publicLine
    }

    /// Saves a pasted OpenSSH private key into the macOS Keychain and derives its public key.
    @discardableResult
    public func importDeployPrivateKey(_ pem: String) async throws -> String {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard trimmed.contains("PRIVATE KEY") else {
            throw GitHubScriptError.invalidPrivateKey
        }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDir.path)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let keyFile = tempDir.appendingPathComponent("imported_key")
        try Data(trimmed.utf8).write(to: keyFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)

        let derived = try await ProcessRunner.run("/usr/bin/ssh-keygen", ["-y", "-f", keyFile.path], timeout: .seconds(10))
        guard derived.succeeded else {
            throw GitHubScriptError.invalidPrivateKey
        }
        let pubKey = derived.output.trimmingCharacters(in: .whitespacesAndNewlines)
        try keychain.set(trimmed, for: GitHubRepoSettings.keychainAccount)
        settings.settings.github.keySource = .keychainDeployKey
        settings.settings.github.deployPublicKey = pubKey
        statusMessage = "Saved read-only deploy key in Keychain."
        errorMessage = nil
        return pubKey
    }

    public func removeDeployKey() {
        try? keychain.remove(GitHubRepoSettings.keychainAccount)
        settings.settings.github.deployPublicKey = ""
        statusMessage = "Removed deploy key from Keychain."
    }

    // MARK: Repository Sync & Verification (Read-Only)

    /// Verifies read-only SSH access to the configured repository using `git ls-remote`.
    @discardableResult
    public func testConnection() async throws -> String {
        let config = settings.settings.github
        let remoteURL = config.normalizedSSHURL
        guard !remoteURL.isEmpty, !remoteURL.hasPrefix("-") else { throw GitHubScriptError.missingRepositoryURL }

        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false }

        return try await withEphemeralSSHCommand(for: config) { env in
            let res = try await ProcessRunner.run(
                "/usr/bin/git",
                ["ls-remote", "--heads", "--tags", "--", remoteURL],
                environment: env,
                timeout: .seconds(20)
            )
            guard res.succeeded else {
                let err = res.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                self.errorMessage = err
                throw GitHubScriptError.gitFailed(err)
            }
            let lines = res.output.split(separator: "\n")
            let summary = "Connected (read-only) — \(lines.count) ref(s) visible on remote."
            self.statusMessage = summary
            return summary
        }
    }

    /// Clones or fetches the latest scripts from the GitHub repository in strictly read-only mode.
    @discardableResult
    public func sync() async throws -> [ScriptPlaybook] {
        let config = settings.settings.github
        let remoteURL = config.normalizedSSHURL
        guard !remoteURL.isEmpty, !remoteURL.hasPrefix("-") else { throw GitHubScriptError.missingRepositoryURL }

        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false }

        let targetDir = paths.githubScripts
        let fm = FileManager.default
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        try await withEphemeralSSHCommand(for: config) { env in
            let gitDir = targetDir.appendingPathComponent(".git")
            let rawBranch = config.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = rawBranch.hasPrefix("-") ? "" : rawBranch

            var needsFreshClone = !fm.fileExists(atPath: gitDir.path)
            if !needsFreshClone {
                let currentRemote = try await ProcessRunner.run(
                    "/usr/bin/git",
                    ["-C", targetDir.path, "remote", "get-url", "origin"],
                    timeout: .seconds(5)
                )
                if currentRemote.output.trimmingCharacters(in: .whitespacesAndNewlines) != remoteURL {
                    needsFreshClone = true
                }
            }

            if needsFreshClone {
                try? fm.removeItem(at: targetDir)
                var args = ["clone", "--depth", "1"]
                if !branch.isEmpty {
                    args += ["--branch", branch]
                }
                args += ["--", remoteURL, targetDir.path]
                let cloneRes = try await ProcessRunner.run("/usr/bin/git", args, environment: env, timeout: .seconds(45))
                guard cloneRes.succeeded else {
                    let err = cloneRes.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.errorMessage = err
                    throw GitHubScriptError.gitFailed(err)
                }
            } else {
                var fetchArgs = ["-C", targetDir.path, "fetch", "--depth", "1", "origin"]
                if !branch.isEmpty { fetchArgs.append(branch) }
                let fetchRes = try await ProcessRunner.run("/usr/bin/git", fetchArgs, environment: env, timeout: .seconds(45))
                guard fetchRes.succeeded else {
                    let err = fetchRes.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.errorMessage = err
                    throw GitHubScriptError.gitFailed(err)
                }
                _ = try await ProcessRunner.run("/usr/bin/git", ["-C", targetDir.path, "reset", "--hard", "FETCH_HEAD"], timeout: .seconds(10))
                _ = try await ProcessRunner.run("/usr/bin/git", ["-C", targetDir.path, "clean", "-fd"], timeout: .seconds(10))
            }

            // Enforce read-only push protection on the local mirror
            _ = try? await ProcessRunner.run(
                "/usr/bin/git",
                ["-C", targetDir.path, "remote", "set-url", "--push", "origin", "no_push_readonly"],
                timeout: .seconds(5)
            )
            // Also mark directory safe for git in case ownership ever differs
            _ = try? await ProcessRunner.run(
                "/usr/bin/git",
                ["config", "--global", "--add", "safe.directory", targetDir.path],
                timeout: .seconds(5)
            )

            let rev = try? await ProcessRunner.run(
                "/usr/bin/git",
                ["-C", targetDir.path, "rev-parse", "--short", "HEAD"],
                timeout: .seconds(5)
            )
            if let sha = rev?.output.trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty {
                self.settings.settings.github.lastSyncedCommit = sha
            }
            self.settings.settings.github.lastSyncedAt = Date()
        }

        reloadFromDisk()
        statusMessage = "Synced \(scripts.count) script\(scripts.count == 1 ? "" : "s")\(settings.settings.github.lastSyncedCommit.map { " (@\($0))" } ?? "")."
        return scripts
    }

    // MARK: Discovering Checked-In Scripts

    public func reloadFromDisk() {
        let root = searchRootDirectory()
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            scripts = []
            return
        }

        var found: [ScriptPlaybook] = []
        let allowedExtensions: Set<String> = ["sh", "bash", "zsh", "fish", "py"]
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let ext = fileURL.pathExtension.lowercased()
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let hasShebang = contents.hasPrefix("#!")
            guard allowedExtensions.contains(ext) || hasShebang else { continue }

            let relPath = relativePath(of: fileURL, from: root)
            let playbook = ScriptPlaybook.parse(fileURL: fileURL, relativePath: relPath, contents: contents)
            found.append(playbook)
        }

        scripts = found.sorted {
            if $0.category != $1.category {
                return $0.category.localizedStandardCompare($1.category) == .orderedAscending
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Brief summary of available GitHub scripts fed into AI Command Assist context so the AI
    /// can recommend or stage checked-in scripts on the fly.
    public var assistContextSummary: String? {
        guard !scripts.isEmpty else { return nil }
        let items = scripts.prefix(15).map { script -> String in
            let vars = script.variables.map(\.name).joined(separator: ",")
            let varSuffix = vars.isEmpty ? "" : " [vars: \(vars)]"
            return "- \(script.relativePath) (\(script.name)): \(script.summary)\(varSuffix)"
        }
        return items.joined(separator: "\n")
    }

    // MARK: Public Repository Split / #dnr Sanitizer

    /// Exports a clean, public-safe copy of the scripts repository to `destination`,
    /// completely omitting `# @dnr` files and stripping all `#dnr` lines and blocks.
    public func exportPublicSafeCopy(to destination: URL) throws -> (exportedFiles: Int, omittedFiles: Int, strippedLines: Int) {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var exportedFiles = 0
        var omittedFiles = 0
        var strippedLines = 0

        for script in scripts {
            let raw = try script.loadContents()
            guard let sanitized = ScriptPlaybook.sanitizeForPublicRelease(raw) else {
                omittedFiles += 1
                continue
            }
            strippedLines += script.dnrLineNumbers.count
            let outURL = destination.appendingPathComponent(script.relativePath)
            try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(sanitized.utf8).write(to: outURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outURL.path)
            exportedFiles += 1
        }
        return (exportedFiles, omittedFiles, strippedLines)
    }

    // MARK: Starter Parameterized Security Templates (Zero Hardcoded Values, #dnr Annotated)

    /// Seeds starter parameterized scripts into the local `github-scripts` directory so the user can
    /// test immediately or copy/commit them into their private GitHub repository.
    public func seedStarterTemplates() throws {
        let root = searchRootDirectory()
        let fm = FileManager.default
        for template in Self.starterTemplates {
            let fileURL = root.appendingPathComponent(template.relativePath)
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(template.contents.utf8).write(to: fileURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        }
        reloadFromDisk()
        statusMessage = "Installed \(Self.starterTemplates.count) starter parameterized scripts (with #dnr examples)."
    }

    public static let starterTemplates: [(relativePath: String, contents: String)] = [
        (
            relativePath: "security/default-system-security.sh",
            contents: """
            #!/usr/bin/env bash
            # @name: Default System Security Baseline
            # @description: Hardens sshd, configures firewall (UFW), enables unattended security updates, and audits sudoers using variables only.
            # @category: security
            # @sudo: true
            # @var: SSH_PORT=22 "SSH daemon listening port"
            # @var: ALLOW_TCP_PORTS=22,80,443 "Comma-separated TCP ports to allow through firewall"
            # @var: PERMIT_ROOT_LOGIN=no "Whether root SSH login is permitted (no / prohibit-password)"
            # @var: INTERNAL_BASTION_CIDR=10.0.0.0/8 "Internal management subnet CIDR" #dnr
            set -euo pipefail

            echo "==> Applying Default System Security Baseline"
            echo "    SSH_PORT=${SSH_PORT:-22} | PERMIT_ROOT_LOGIN=${PERMIT_ROOT_LOGIN:-no}"

            # 1. SSH Daemon Hardening (Drop-in config, no hardcoded values)
            if [ -d /etc/ssh/sshd_config.d ]; then
                cat <<EOF >/etc/ssh/sshd_config.d/90-harbor-hardening.conf
            Port ${SSH_PORT:-22}
            PermitRootLogin ${PERMIT_ROOT_LOGIN:-no}
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            X11Forwarding no
            MaxAuthTries 3
            ClientAliveInterval 300
            ClientAliveCountMax 2
            EOF
                echo "    [ok] Wrote /etc/ssh/sshd_config.d/90-harbor-hardening.conf"
            fi

            # 2. Internal Bastion Allowlist Rule (marked #dnr so it is stripped if repo is split to public)
            #dnr-start
            if command -v ufw >/dev/null 2>&1 && [ -n "${INTERNAL_BASTION_CIDR:-}" ]; then
                ufw allow from "${INTERNAL_BASTION_CIDR}" to any port "${SSH_PORT:-22}" proto tcp comment "Internal Bastion" #dnr
            fi
            #dnr-end

            # 3. Host Firewall Baseline
            if command -v ufw >/dev/null 2>&1; then
                ufw default deny incoming
                ufw default allow outgoing
                IFS=',' read -ra PORTS <<< "${ALLOW_TCP_PORTS:-22,80,443}"
                for port in "${PORTS[@]}"; do
                    ufw allow "${port}/tcp"
                done
                ufw --force enable
                ufw status verbose
            fi

            # 4. Unattended Security Upgrades (Debian/Ubuntu)
            if command -v apt-get >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get update -qq
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades fail2ban
                systemctl enable --now fail2ban 2>/dev/null || true
            fi

            echo "==> Security baseline complete."
            """
        ),
        (
            relativePath: "security/ssh-and-auth-audit.sh",
            contents: """
            #!/usr/bin/env bash
            # @name: SSH & Privilege Audit
            # @description: Read-only audit of authorized_keys, sshd effective config, sudoers, and listening sockets.
            # @category: security
            # @sudo: false
            # @var: TARGET_USER= "Optional user to inspect (defaults to current user)"
            set -euo pipefail

            INSPECT_USER="${TARGET_USER:-$(whoami)}"
            echo "=== Host Security & SSH Audit (${INSPECT_USER}@$(hostname)) ==="
            uname -a

            echo ""
            echo "--- Authorized SSH Keys ---"
            AUTH_FILE="${HOME}/.ssh/authorized_keys"
            if [ -f "${AUTH_FILE}" ]; then
                awk '{print NR ": " $1 " " $3}' "${AUTH_FILE}"
            else
                echo "No authorized_keys file found at ${AUTH_FILE}"
            fi

            echo ""
            echo "--- Listening Network Sockets ---"
            if command -v ss >/dev/null 2>&1; then
                ss -tulpn
            elif command -v lsof >/dev/null 2>&1; then
                lsof -iTCP -sTCP:LISTEN -P -n
            fi

            echo ""
            echo "--- Passwordless Sudoers Check ---"
            grep -rn "NOPASSWD" /etc/sudoers /etc/sudoers.d/ 2>/dev/null || echo "None readable without sudo"
            """
        ),
        (
            relativePath: "diagnostics/system-health-snapshot.sh",
            contents: """
            #!/usr/bin/env bash
            # @name: System Health Snapshot
            # @description: Collects CPU load, memory pressure, disk usage, failed systemd units, and recent kernel warnings.
            # @category: diagnostics
            # @sudo: false
            # @var: LOG_LINES=25 "Number of recent error log lines to include"
            set -euo pipefail

            echo "=== System Health Snapshot ($(hostname)) ==="
            uptime
            echo ""
            df -h
            echo ""
            if command -v free >/dev/null 2>&1; then
                free -h
            elif command -v vm_stat >/dev/null 2>&1; then
                vm_stat | head -n 10
            fi
            echo ""
            if command -v systemctl >/dev/null 2>&1; then
                echo "--- Failed Systemd Services ---"
                systemctl --failed --no-pager || true
            fi
            """
        )
    ]

    // MARK: Private Helpers

    private func searchRootDirectory() -> URL {
        let sub = settings.settings.github.scriptsSubdirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sub.isEmpty else { return paths.githubScripts }
        let root = paths.githubScripts.standardizedFileURL
        let candidate = root.appendingPathComponent(sub, isDirectory: true).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            return paths.githubScripts
        }
        return candidate
    }

    private func relativePath(of fileURL: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return fileURL.lastPathComponent
    }

    private func withEphemeralSSHCommand<T>(
        for config: GitHubRepoSettings,
        operation: ([String: String]) async throws -> T
    ) async throws -> T {
        let remoteURL = config.normalizedSSHURL
        // Local path or file:// URLs used in tests don't need an SSH key
        if remoteURL.hasPrefix("/") || remoteURL.hasPrefix("file://") {
            return try await operation([:])
        }

        let keyPath: String
        var cleanupURL: URL?

        switch config.keySource {
        case .keychainDeployKey:
            guard let pem = try keychain.string(for: GitHubRepoSettings.keychainAccount),
                  !pem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GitHubScriptError.missingDeployKey
            }
            let ephemeral = paths.githubDeployKey
            let parentDir = ephemeral.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parentDir.path)
            let normalizedPEM = pem.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            try? FileManager.default.removeItem(at: ephemeral)
            FileManager.default.createFile(
                atPath: ephemeral.path,
                contents: Data(normalizedPEM.utf8),
                attributes: [.posixPermissions: 0o600]
            )
            keyPath = ephemeral.path
            cleanupURL = ephemeral

        case .sshKeyFile:
            guard let path = config.sshKeyPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else {
                throw GitHubScriptError.missingDeployKey
            }
            keyPath = path
        }

        defer {
            if let cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }

        let quotedKey = ScriptPlaybook.shellSingleQuote(keyPath)
        let sshCommand = "/usr/bin/ssh -i \(quotedKey) -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
        var env = ProcessInfo.processInfo.environment
        env["GIT_SSH_COMMAND"] = sshCommand
        env["GIT_TERMINAL_PROMPT"] = "0"
        return try await operation(env)
    }
}
