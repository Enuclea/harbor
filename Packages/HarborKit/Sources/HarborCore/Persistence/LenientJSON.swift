import Foundation

/// Forward- and backward-compatible JSON decoding.
///
/// The stored document is deep-merged over the encoded defaults before decoding, so
/// keys added in a newer version get their default, unknown keys are ignored, and a
/// hand-edited file with a missing section still loads.
public enum LenientJSON {
    public static func decode<Value: Codable>(_ type: Value.Type, from data: Data, defaults: Value) throws -> Value {
        let encoder = JSONEncoder()
        let base = try JSONSerialization.jsonObject(with: encoder.encode(defaults))
        let stored = try JSONSerialization.jsonObject(with: data)
        let merged = merge(base, stored)
        let mergedData = try JSONSerialization.data(withJSONObject: merged)
        return try JSONDecoder.harbor.decode(Value.self, from: mergedData)
    }

    /// Objects merge key by key; anything else (arrays, scalars) is replaced by the stored value.
    static func merge(_ base: Any, _ override: Any) -> Any {
        guard let baseObject = base as? [String: Any], let overrideObject = override as? [String: Any] else {
            return override is NSNull ? base : override
        }
        var result = baseObject
        for (key, value) in overrideObject {
            result[key] = result[key].map { merge($0, value) } ?? value
        }
        return result
    }
}

extension JSONEncoder {
    /// Stable, readable output for files users may open or diff.
    public static var harbor: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var harbor: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
