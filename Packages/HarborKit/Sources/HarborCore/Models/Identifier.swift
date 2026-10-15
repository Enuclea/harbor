import Foundation

/// A strongly-typed UUID. `Tag` is a phantom type so a `SessionID` can never be passed
/// where a `HostID` is expected. Encodes as a plain lowercase UUID string.
public struct Identifier<Tag>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let uuid: UUID

    public init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }

    public init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.uuid = uuid
    }

    public var description: String { uuid.uuidString.lowercased() }

    /// The first eight characters — enough to disambiguate tabs in logs and AI tool output.
    public var shortDescription: String { String(description.prefix(8)) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let uuid = UUID(uuidString: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid identifier '\(raw)'")
        }
        self.uuid = uuid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public enum SessionIdentifierTag {}
public enum HostIdentifierTag {}

public typealias SessionID = Identifier<SessionIdentifierTag>
public typealias HostID = Identifier<HostIdentifierTag>
