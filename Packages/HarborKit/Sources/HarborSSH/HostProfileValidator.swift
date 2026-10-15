import Foundation
import HarborCore

public enum HostProfileProblem: Error, LocalizedError, Equatable {
    case invalidHostname
    case invalidUser
    case invalidPort
    case invalidJumpHost
    case invalidIdentityFile

    public var errorDescription: String? {
        switch self {
        case .invalidHostname: "The host name is empty or contains characters ssh can't use."
        case .invalidUser: "The user name contains characters ssh can't use."
        case .invalidPort: "The port must be between 1 and 65535."
        case .invalidJumpHost: "The jump host isn't valid."
        case .invalidIdentityFile: "The identity file path isn't valid."
        }
    }
}

/// Rejects profiles that could smuggle options into ssh (any value starting with `-`)
/// or that ssh would refuse anyway. Applied when saving and again before connecting,
/// because profiles also arrive from files, imports and AI assistants.
public enum HostProfileValidator {
    public static func problems(in host: HostProfile) -> [HostProfileProblem] {
        var problems: [HostProfileProblem] = []
        if !SSHDestination.isValidHost(host.hostname) { problems.append(.invalidHostname) }
        if let user = host.user, !user.isEmpty, !SSHDestination.isValidUser(user) { problems.append(.invalidUser) }
        if let port = host.port, !(1...65_535).contains(port) { problems.append(.invalidPort) }
        if let jump = host.jumpHost, !jump.isEmpty {
            let hops = jump.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let valid = hops.allSatisfy { hop in
                !hop.hasPrefix("-") && (try? SSHDestination.parse(hop)) != nil
            }
            if !valid { problems.append(.invalidJumpHost) }
        }
        if let identity = host.identityFile, identity.hasPrefix("-") || identity.contains("\n") {
            problems.append(.invalidIdentityFile)
        }
        return problems
    }

    public static func validate(_ host: HostProfile) throws {
        if let problem = problems(in: host).first { throw problem }
    }
}
