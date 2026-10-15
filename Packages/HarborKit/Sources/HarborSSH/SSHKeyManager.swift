import Foundation
import HarborCore
import HarborLogging
import HarborPTY

/// A key pair found in `~/.ssh`.
public struct SSHKey: Identifiable, Hashable, Sendable {
    public var id: String { privateKeyPath }
    public let privateKeyPath: String
    public let publicKeyPath: String
    /// e.g. `ED25519`, `RSA`, `ECDSA`, `ED25519-SK`.
    public let type: String
    public let bits: Int
    /// `SHA256:…`
    public let fingerprint: String
    public let comment: String
    public let publicKey: String
    public var isLoadedInAgent: Bool

    public var fileName: String { (privateKeyPath as NSString).lastPathComponent }
}

public enum SSHKeyError: Error, LocalizedError {
    case alreadyExists(String)
    case invalidName(String)
    case notAPrivateKey
    case toolFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let path): "A key already exists at \(path)."
        case .invalidName(let name): "“\(name)” can't be used as a key file name."
        case .notAPrivateKey: "That file isn't an SSH private key."
        case .toolFailed(let message): message
        }
    }
}

/// Lists, creates, imports and loads SSH keys using the system's OpenSSH tools.
///
/// Passphrases are typed into the tools through a PTY (`ExpectSession`), never passed
/// as arguments, so they can't be read from the process table.
public struct SSHKeyManager: Sendable {
    public let sshDirectory: URL
    private let log = Log(.ssh)

    public init(sshDirectory: URL) {
        self.sshDirectory = sshDirectory
    }

    // MARK: Listing

    public func listKeys() async -> [SSHKey] {
        let loaded = await agentFingerprints()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: sshDirectory.path)) ?? []
        var keys: [SSHKey] = []
        for file in files.sorted() where file.hasSuffix(".pub") {
            let publicPath = sshDirectory.appending(path: file).path
            let privatePath = String(publicPath.dropLast(4))
            guard FileManager.default.fileExists(atPath: privatePath),
                  var key = await describe(publicKeyPath: publicPath, privateKeyPath: privatePath) else { continue }
            key.isLoadedInAgent = loaded.contains(key.fingerprint)
            keys.append(key)
        }
        return keys
    }

    /// Fingerprints of keys currently loaded in the SSH agent.
    public func agentFingerprints() async -> Set<String> {
        guard let result = try? await ProcessRunner.run("/usr/bin/ssh-add", ["-l"], timeout: .seconds(5)), result.succeeded else {
            return []
        }
        return Set(result.output.split(separator: "\n").compactMap { line in
            line.split(separator: " ").dropFirst().first.map(String.init)
        })
    }

    // MARK: Creating

    /// Generates an Ed25519 key (`-a 100` KDF rounds) at `~/.ssh/<name>`.
    public func generateKey(name: String, comment: String, passphrase: String?) async throws -> SSHKey {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), !name.hasPrefix("-") else {
            throw SSHKeyError.invalidName(name)
        }
        try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
        let privatePath = sshDirectory.appending(path: name).path
        guard !FileManager.default.fileExists(atPath: privatePath) else { throw SSHKeyError.alreadyExists(privatePath) }

        var arguments = ["-t", "ed25519", "-a", "100", "-C", comment, "-f", privatePath]
        let secret = passphrase ?? ""
        if secret.isEmpty { arguments += ["-N", ""] }
        let session = try await ExpectSession.launch(executable: "/usr/bin/ssh-keygen", arguments: arguments)
        if !secret.isEmpty {
            try await session.expect("passphrase")
            await session.sendLine(secret)
            try await session.expect("same passphrase")
            await session.sendLine(secret)
        }
        let (status, transcript) = await session.waitForExit(timeout: .seconds(30))
        guard status == .exited(0) else {
            throw SSHKeyError.toolFailed("ssh-keygen failed: \(transcript.suffix(200))")
        }
        log.notice("generated key \(name)")
        guard let key = await describe(publicKeyPath: privatePath + ".pub", privateKeyPath: privatePath) else {
            throw SSHKeyError.toolFailed("The new key could not be read back.")
        }
        return key
    }

    /// Adds a key to the agent. With `storeInKeychain`, macOS remembers the passphrase so
    /// it is never asked for again (`ssh-add --apple-use-keychain`).
    public func addToAgent(_ key: SSHKey, passphrase: String?, storeInKeychain: Bool) async throws {
        let arguments = (storeInKeychain ? ["--apple-use-keychain"] : []) + [key.privateKeyPath]
        let session = try await ExpectSession.launch(executable: "/usr/bin/ssh-add", arguments: arguments)
        let outcome = try await session.expectAny(["Enter passphrase", "Identity added"], timeout: .seconds(10))
        if outcome == 0 {
            await session.sendLine(passphrase ?? "")
            let result = try await session.expectAny(["Identity added", "Bad passphrase", "incorrect passphrase"], timeout: .seconds(10))
            if result != 0 { throw SSHKeyError.toolFailed("The passphrase was not accepted.") }
        }
        _ = await session.waitForExit(timeout: .seconds(5))
        log.notice("added \(key.fileName) to agent", ["keychain": "\(storeInKeychain)"])
    }

    // MARK: Importing

    /// Copies a dropped private key into `~/.ssh` with `0600` and recreates its public half.
    public func importPrivateKey(from source: URL, passphrase: String? = nil) async throws -> SSHKey {
        let data = try Data(contentsOf: source)
        guard let header = String(data: data.prefix(64), encoding: .utf8), header.contains("PRIVATE KEY") else {
            throw SSHKeyError.notAPrivateKey
        }
        var name = source.lastPathComponent
        while FileManager.default.fileExists(atPath: sshDirectory.appending(path: name).path) { name += "-imported" }
        let destination = sshDirectory.appending(path: name)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

        let session = try await ExpectSession.launch(executable: "/usr/bin/ssh-keygen", arguments: ["-y", "-f", destination.path])
        if (try? await session.expectAny(["passphrase", "ssh-"], timeout: .seconds(5))) == 0 {
            await session.sendLine(passphrase ?? "")
        }
        let (status, transcript) = await session.waitForExit(timeout: .seconds(10))
        guard status == .exited(0), let line = transcript.split(separator: "\n").last(where: { $0.hasPrefix("ssh-") || $0.hasPrefix("ecdsa-") || $0.hasPrefix("sk-") }) else {
            try? FileManager.default.removeItem(at: destination)
            throw SSHKeyError.toolFailed("Couldn't read the key. If it has a passphrase, enter it and try again.")
        }
        try (line.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").write(toFile: destination.path + ".pub", atomically: true, encoding: .utf8)
        log.notice("imported key \(name)")
        guard let key = await describe(publicKeyPath: destination.path + ".pub", privateKeyPath: destination.path) else {
            throw SSHKeyError.toolFailed("The imported key could not be read back.")
        }
        return key
    }

    // MARK: Helpers

    private func describe(publicKeyPath: String, privateKeyPath: String) async -> SSHKey? {
        guard let publicKey = try? String(contentsOfFile: publicKeyPath, encoding: .utf8),
              let result = try? await ProcessRunner.run("/usr/bin/ssh-keygen", ["-l", "-f", publicKeyPath], timeout: .seconds(5)),
              result.succeeded else { return nil }
        // "256 SHA256:abc… comment words (ED25519)"
        let line = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        var rest = parts.count > 2 ? parts[2] : ""
        var type = "KEY"
        if let open = rest.lastIndex(of: "("), rest.hasSuffix(")") {
            type = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
            rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return SSHKey(
            privateKeyPath: privateKeyPath, publicKeyPath: publicKeyPath, type: type, bits: Int(parts[0]) ?? 0,
            fingerprint: parts[1], comment: rest, publicKey: publicKey.trimmingCharacters(in: .whitespacesAndNewlines),
            isLoadedInAgent: false)
    }
}
