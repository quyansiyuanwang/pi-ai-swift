import Foundation

/// A self-contained representation of a JSON value.
///
/// Replaces the upstream TypeScript `JsonValue` / `JsonObject` types without
/// pulling in any third-party dependency. Integers and floating point numbers
/// are kept distinct so JSON schemas such as `{"minimum": 1}` round-trip
/// losslessly.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

/// A JSON object (`{ [key: string]: JsonValue }` upstream).
public typealias JSONObject = [String: JSONValue]

/// A JSON array (`readonly JsonValue[]` upstream).
public typealias JSONArray = [JSONValue]

extension JSONValue {
    /// Builds a numeric value, collapsing whole numbers that fit in `Int` to `.int`.
    public static func number(_ value: Double) -> JSONValue {
        if value.isFinite, value.rounded() == value,
           value >= Double(Int.min), value <= Double(Int.max) {
            return .int(Int(value))
        }
        return .double(value)
    }

    /// Builds a numeric value from an integer.
    public static func number(_ value: Int) -> JSONValue {
        .int(value)
    }
}

// MARK: - Accessors

extension JSONValue {
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value: return Int(exactly: value)
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

    public var objectValue: JSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }
}

// MARK: - Subscripts

extension JSONValue {
    /// Object member access. Returns `.null` for missing keys.
    public subscript(key: String) -> JSONValue {
        get {
            if case .object(let object) = self { return object[key] ?? .null }
            return .null
        }
        set {
            if case .object(var object) = self {
                object[key] = newValue
                self = .object(object)
            } else {
                self = .object([key: newValue])
            }
        }
    }

    /// Array element access. Returns `.null` when out of bounds.
    public subscript(index: Int) -> JSONValue {
        get {
            guard case .array(let array) = self, array.indices.contains(index) else { return .null }
            return array[index]
        }
        set {
            guard case .array(var array) = self, array.indices.contains(index) else { return }
            array[index] = newValue
            self = .array(array)
        }
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode(JSONObject.self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
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

// MARK: - Literal conversions

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
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - Codable bridging helpers

extension JSONValue {
    /// Encodes an arbitrary `Encodable` value into its JSON representation.
    public init<T: Encodable>(encoding value: T, encoder: JSONEncoder = JSONEncoder()) throws {
        let data = try encoder.encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this JSON representation into an arbitrary `Decodable` value.
    public func decoded<T: Decodable>(as type: T.Type = T.self, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try decoder.decode(T.self, from: data)
    }
}
