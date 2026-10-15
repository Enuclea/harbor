import Foundation
import HarborControl

/// What a tool returns: text for the model, and whether it represents a failure.
public struct MCPToolResult: Sendable {
    public let text: String
    public let isError: Bool

    public static func text(_ text: String) -> MCPToolResult { MCPToolResult(text: text, isError: false) }
    public static func error(_ text: String) -> MCPToolResult { MCPToolResult(text: text, isError: true) }

    /// Pretty JSON, so models can read structured results reliably.
    public static func json<T: Encodable>(_ value: T) -> MCPToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data("null".utf8)
        return .text(String(decoding: data, as: UTF8.self))
    }

    var json: JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }
}

/// MCP tool hints, so clients can auto-approve reads and warn on writes.
public struct MCPToolAnnotations: Sendable {
    public var readOnly: Bool
    public var destructive: Bool
    public var idempotent: Bool

    var json: JSONValue {
        ["readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive),
         "idempotentHint": .bool(idempotent), "openWorldHint": false]
    }
}

/// One callable tool.
public struct MCPTool: Sendable {
    public typealias Handler = @Sendable (_ arguments: MCPArguments, _ client: ControlClient) async throws -> MCPToolResult

    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: JSONValue
    public let annotations: MCPToolAnnotations
    public let handler: Handler

    var listing: JSONValue {
        ["name": .string(name), "title": .string(title), "description": .string(description),
         "inputSchema": inputSchema, "annotations": annotations.json]
    }
}

/// Typed access to tool arguments with helpful errors.
public struct MCPArguments: Sendable {
    let values: [String: JSONValue]

    init(_ value: JSONValue?) {
        if case .object(let object) = value { values = object } else { values = [:] }
    }

    public func string(_ key: String) -> String? {
        values[key]?.stringValue ?? values[key]?.intValue.map(String.init)
    }

    public func requiredString(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else {
            throw ControlError.invalidArgument("Missing required argument “\(key)”.")
        }
        return value
    }

    public func int(_ key: String) -> Int? { values[key]?.intValue }
    public func bool(_ key: String) -> Bool? { values[key]?.boolValue }

    public func strings(_ key: String) -> [String]? {
        if let array = values[key]?.arrayValue { return array.compactMap(\.stringValue) }
        if let single = values[key]?.stringValue { return [single] }
        return nil
    }

    /// The `tab` argument, defaulting to the focused tab.
    public var tab: String { string("tab") ?? "current" }
}

/// JSON Schema helpers for tool inputs.
enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
         "additionalProperties": false]
    }

    static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "integer", "description": .string(description)]
        if let minimum { schema["minimum"] = .number(Double(minimum)) }
        if let maximum { schema["maximum"] = .number(Double(maximum)) }
        return .object(schema)
    }

    static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    static func stringArray(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }

    static let tab = string("Which tab: a 1-based index from list_tabs, a tab id, or “current” (the default) for the focused tab.")
}
