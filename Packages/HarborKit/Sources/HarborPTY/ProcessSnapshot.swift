import CHarborPTY
import Foundation

/// Name and working directory of a running process, read via libproc.
public struct ProcessSnapshot: Sendable, Equatable {
    public let pid: pid_t
    public let name: String
    public let workingDirectory: String?

    public init?(pid: pid_t) {
        guard pid > 0 else { return nil }
        self.pid = pid
        var nameBuffer = [CChar](repeating: 0, count: 256)
        let nameLength = harbor_process_name(pid, &nameBuffer, Int32(nameBuffer.count))
        guard nameLength > 0 else { return nil }
        name = String(decoding: nameBuffer.prefix(Int(nameLength)).map { UInt8(bitPattern: $0) }, as: UTF8.self)

        var cwdBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let cwdLength = harbor_process_cwd(pid, &cwdBuffer, Int32(cwdBuffer.count))
        workingDirectory = cwdLength > 0
            ? String(decoding: cwdBuffer.prefix(Int(cwdLength)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : nil
    }

    /// Shells and login wrappers — closing a tab that is only running one of these needs no confirmation.
    public var isShell: Bool {
        let bare = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "elvish", "xonsh", "login"].contains(bare)
    }
}
