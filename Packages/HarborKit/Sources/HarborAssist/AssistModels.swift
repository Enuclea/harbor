import Foundation
import HarborCore
import Observation

/// Token counts reported by (or estimated for) an onboard AI request.
public struct TokenUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public var totalTokens: Int { inputTokens + outputTokens }
}

/// Tracks cumulative token usage for the running Harbor session so the user always sees
/// the exact cost of onboard AI assistance.
@MainActor
@Observable
public final class TokenLedger {
    public private(set) var inputTokens = 0
    public private(set) var outputTokens = 0
    public private(set) var requestCount = 0
    public private(set) var lastUsage: TokenUsage?

    public init() {}

    public var totalTokens: Int { inputTokens + outputTokens }

    public func record(_ usage: TokenUsage) {
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        requestCount += 1
        lastUsage = usage
    }

    public func reset() {
        inputTokens = 0
        outputTokens = 0
        requestCount = 0
        lastUsage = nil
    }
}

/// Minimal, redacted context about a terminal tab passed to `HarborAssist`.
public struct AssistContext: Sendable, Equatable {
    public var shell: String
    public var isRemote: Bool
    public var hostLabel: String?
    public var workingDirectory: String?
    public var lastCommand: String?
    public var lastExitCode: Int32?
    public var systemProfileJSON: String?
    public var rawOutput: String

    public init(
        shell: String = "zsh",
        isRemote: Bool = false,
        hostLabel: String? = nil,
        workingDirectory: String? = nil,
        lastCommand: String? = nil,
        lastExitCode: Int32? = nil,
        systemProfileJSON: String? = nil,
        rawOutput: String = ""
    ) {
        self.shell = shell
        self.isRemote = isRemote
        self.hostLabel = hostLabel
        self.workingDirectory = workingDirectory
        self.lastCommand = lastCommand
        self.lastExitCode = lastExitCode
        self.systemProfileJSON = systemProfileJSON
        self.rawOutput = rawOutput
    }
}

/// Structured response from `HarborAssist`: a concise explanation and an optional shell
/// command that the user can stage into their prompt with one click.
public struct AssistResult: Sendable, Equatable {
    public let explanation: String
    public let suggestedCommand: String?
    public let usage: TokenUsage
    public let truncatedLines: Int

    public init(explanation: String, suggestedCommand: String?, usage: TokenUsage, truncatedLines: Int = 0) {
        self.explanation = explanation
        self.suggestedCommand = suggestedCommand
        self.usage = usage
        self.truncatedLines = truncatedLines
    }
}

public enum AssistError: Error, LocalizedError, Equatable {
    case disabled
    case missingAPIKey(AIProviderKind)
    case invalidEndpoint(String)
    case httpError(Int, String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .disabled:
            "Onboard AI Assist is turned off in Settings ▸ AI & MCP."
        case .missingAPIKey(let provider):
            "No API key is saved in Keychain for \(provider.label). Add one in Settings ▸ AI & MCP."
        case .invalidEndpoint(let url):
            "Invalid API endpoint URL: \(url)"
        case .httpError(let status, let message):
            "AI provider returned HTTP \(status): \(message)"
        case .emptyResponse:
            "The AI provider returned an empty response."
        }
    }
}
