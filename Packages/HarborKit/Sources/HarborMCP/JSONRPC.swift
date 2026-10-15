import Foundation

/// A JSON-RPC 2.0 request id (string or number).
public enum JSONRPCID: Codable, Sendable, Hashable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) { self = .number(number) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// An incoming request (with `id`) or notification (without).
public struct JSONRPCRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let method: String
    public let params: JSONValue?

    public var isNotification: Bool { id == nil }
}

public struct JSONRPCError: Codable, Sendable, Error, Equatable {
    public let code: Int
    public let message: String

    public static let parseError = -32_700
    public static let invalidRequest = -32_600
    public static let methodNotFound = -32_601
    public static let invalidParams = -32_602
    public static let internalError = -32_603

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public struct JSONRPCResponse: Codable, Sendable {
    public var jsonrpc = "2.0"
    public let id: JSONRPCID?
    public let result: JSONValue?
    public let error: JSONRPCError?

    public static func success(_ id: JSONRPCID?, _ result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result, error: nil)
    }

    public static func failure(_ id: JSONRPCID?, _ error: JSONRPCError) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: nil, error: error)
    }

    /// One line of newline-delimited JSON, as the MCP stdio transport requires.
    public func encodedLine() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var data = (try? encoder.encode(self)) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"encoding failed"}}"#.utf8)
        data.append(0x0A)
        return data
    }
}
