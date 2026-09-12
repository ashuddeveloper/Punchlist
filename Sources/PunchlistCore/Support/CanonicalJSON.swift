import Crypto
import Foundation

/// Deterministic JSON encoding, used for the frozen template snapshot and its
/// hash.
///
/// Ordinary `JSONEncoder` emits keys in declaration order, so the same snapshot
/// could hash differently depending on how the object was built or which Swift
/// version reordered a synthesised `CodingKeys`. `.sortedKeys` removes that,
/// and `.withoutEscapingSlashes` keeps the bytes stable across Foundation
/// versions that changed the default.
///
/// The snapshot model deliberately contains no `Double` fields. Floating-point
/// formatting is the classic source of "identical data, different bytes" and
/// there is nothing in a template that needs one.
public enum CanonicalJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder().encode(value)
        guard let s = String(data: data, encoding: .utf8) else {
            throw CanonicalJSONError.notUTF8
        }
        return s
    }

    public static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8) else { throw CanonicalJSONError.notUTF8 }
        return try decoder().decode(type, from: data)
    }

    public static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Hash of a value's canonical encoding. This is what makes "did this
    /// template change?" a string comparison rather than a structural diff.
    public static func hash<T: Encodable>(_ value: T) throws -> String {
        sha256Hex(try encode(value))
    }
}

public enum CanonicalJSONError: Error {
    case notUTF8
}
