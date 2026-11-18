import Foundation
import HarborCore

/// Sends prompts to the configured LLM provider (Anthropic, OpenAI-compatible, Gemini, or local Ollama).
/// Secrets are passed per-call from Keychain and are never logged.
public struct AIProviderClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let transport: Transport

    public init(transport: @escaping Transport = Self.urlSessionTransport) {
        self.transport = transport
    }

    public static let urlSessionTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AssistError.httpError(0, "Non-HTTP response")
        }
        return (data, http)
    }

    public struct CompletionResponse: Sendable, Equatable {
        public let text: String
        public let usage: TokenUsage
    }

    public func complete(
        system: String,
        user: String,
        settings: OnboardAISettings,
        apiKey: String?
    ) async throws -> CompletionResponse {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.provider.requiresAPIKey, (key == nil || key?.isEmpty == true) {
            throw AssistError.missingAPIKey(settings.provider)
        }

        let request = try buildRequest(system: system, user: user, settings: settings, apiKey: key)
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            let detail = Self.extractErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw AssistError.httpError(response.statusCode, detail)
        }
        return try parseResponse(data: data, provider: settings.provider, fallbackInput: system + "\n" + user)
    }

    // MARK: Request builders

    private func buildRequest(
        system: String,
        user: String,
        settings: OnboardAISettings,
        apiKey: String?
    ) throws -> URLRequest {
        let model = settings.effectiveModel
        let maxOut = max(64, settings.maxOutputTokens)

        switch settings.provider {
        case .anthropic:
            guard let url = URL(string: settings.effectiveEndpoint) else {
                throw AssistError.invalidEndpoint(settings.effectiveEndpoint)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
            let body: [String: Any] = [
                "model": model,
                "max_tokens": maxOut,
                "system": system,
                "messages": [
                    ["role": "user", "content": user]
                ]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request

        case .openAICompatible, .localOllama:
            guard let url = URL(string: settings.effectiveEndpoint) else {
                throw AssistError.invalidEndpoint(settings.effectiveEndpoint)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            let body: [String: Any] = [
                "model": model,
                "max_tokens": maxOut,
                "temperature": 0.1,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user]
                ]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request

        case .gemini:
            let base = settings.effectiveEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let urlString = "\(base)/\(model):generateContent"
            guard let url = URL(string: urlString) else {
                throw AssistError.invalidEndpoint(urlString)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key") }
            let body: [String: Any] = [
                "systemInstruction": [
                    "parts": [["text": system]]
                ],
                "contents": [
                    ["role": "user", "parts": [["text": user]]]
                ],
                "generationConfig": [
                    "maxOutputTokens": maxOut,
                    "temperature": 0.1
                ]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        }
    }

    // MARK: Response parsers

    private func parseResponse(data: Data, provider: AIProviderKind, fallbackInput: String) throws -> CompletionResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistError.emptyResponse
        }

        switch provider {
        case .anthropic:
            let content = (json["content"] as? [[String: Any]])?
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !content.isEmpty else { throw AssistError.emptyResponse }
            let usageDict = json["usage"] as? [String: Any]
            let input = (usageDict?["input_tokens"] as? Int) ?? ContextBudgeter.estimateTokens(fallbackInput)
            let output = (usageDict?["output_tokens"] as? Int) ?? ContextBudgeter.estimateTokens(content)
            return CompletionResponse(text: content, usage: TokenUsage(inputTokens: input, outputTokens: output))

        case .openAICompatible, .localOllama:
            let choices = json["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            let content = (message?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !content.isEmpty else { throw AssistError.emptyResponse }
            let usageDict = json["usage"] as? [String: Any]
            let input = (usageDict?["prompt_tokens"] as? Int) ?? ContextBudgeter.estimateTokens(fallbackInput)
            let output = (usageDict?["completion_tokens"] as? Int) ?? ContextBudgeter.estimateTokens(content)
            return CompletionResponse(text: content, usage: TokenUsage(inputTokens: input, outputTokens: output))

        case .gemini:
            let candidates = json["candidates"] as? [[String: Any]]
            let contentObj = candidates?.first?["content"] as? [String: Any]
            let parts = contentObj?["parts"] as? [[String: Any]]
            let content = parts?
                .filter { ($0["thought"] as? Bool) != true }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !content.isEmpty else { throw AssistError.emptyResponse }
            let usageDict = json["usageMetadata"] as? [String: Any]
            let input = (usageDict?["promptTokenCount"] as? Int) ?? ContextBudgeter.estimateTokens(fallbackInput)
            let output = (usageDict?["candidatesTokenCount"] as? Int) ?? ContextBudgeter.estimateTokens(content)
            return CompletionResponse(text: content, usage: TokenUsage(inputTokens: input, outputTokens: output))
        }
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data.prefix(240), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return RedactorValue.clean(message)
        }
        if let error = json["error"] as? String {
            return RedactorValue.clean(error)
        }
        return nil
    }
}

private enum RedactorValue {
    static func clean(_ value: String) -> String {
        String(value.prefix(240))
    }
}
