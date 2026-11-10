import Foundation

/// A JSON value.
///
/// Live Sync exchanges two kinds of loosely typed JSON with the conversation engine: the JSON
/// Schemas that describe an action's parameters, and the payloads the engine sends back when the
/// customer invokes one. `JSONValue` models both without forcing callers through `Any` casts.
///
/// Schemas read naturally thanks to literal conformances:
///
/// ```swift
/// let schema: JSONValue = [
///     "type": "object",
///     "properties": [
///         "fullName": ["type": "string"],
///         "email": ["type": "string"],
///     ],
/// ]
/// ```
///
/// Payloads can be read with the accessors (``stringValue``, subscripts) or decoded straight into
/// a `Decodable` model with ``decode(_:using:)``.
/// Numeric note: decoding tries `Int` before `Double`, so an integral number written as `3.0` on the
/// wire decodes as `.int(3)`, and the synthesized `Equatable` treats `.int(3)` and `.double(3.0)` as
/// different. Compare numbers with `doubleValue` (which bridges both) rather than by case when the
/// source is the engine; `Equatable` is for structural comparison of values you built yourself.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable as JSON"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Reading

extension JSONValue {
    public var isNull: Bool { self == .null }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(exactly: value.rounded())
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// The value for `key`, or `nil` when this is not an object or the key is absent.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// The element at `index`, or `nil` when this is not an array or the index is out of bounds.
    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

// MARK: - Bridging to Codable models

extension JSONValue {
    /// Wraps any `Encodable` value as a `JSONValue`.
    public init(encoding value: some Encodable, using encoder: JSONEncoder = JSONEncoder()) throws {
        let data = try encoder.encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this value into `type`.
    public func decode<T: Decodable>(
        _ type: T.Type,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        if let value = self as? T { return value }
        let data = try JSONEncoder().encode(self)
        return try decoder.decode(T.self, from: data)
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8)
        else { return "<invalid JSON>" }
        return text
    }
}
