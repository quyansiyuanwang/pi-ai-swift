import Foundation

/// The JSON Schema primitive types accepted by the `type` keyword.
public enum JSONSchemaType: String, Sendable, Codable, Hashable, CaseIterable {
    case string
    case number
    case integer
    case boolean
    case object
    case array
    case null
}

/// A reference box that breaks the recursive value-type cycle for single
/// nested schemas (`items`, `not`).
public final class JSONSchemaBox: Sendable, Hashable {
    public let schema: JSONSchema

    public init(_ schema: JSONSchema) {
        self.schema = schema
    }

    public static func == (lhs: JSONSchemaBox, rhs: JSONSchemaBox) -> Bool {
        lhs.schema == rhs.schema
    }

    public func hash(into hasher: inout Hasher) {
        schema.hash(into: &hasher)
    }
}

/// The value of the JSON Schema `additionalProperties` keyword.
public indirect enum JSONSchemaAdditionalProperties: Sendable, Hashable {
    case bool(Bool)
    case schema(JSONSchema)
}

/// A self-contained JSON Schema representation.
///
/// Replaces the upstream TypeBox `TSchema` without any third-party dependency.
/// The type models the JSON Schema subset used by tool definitions and
/// constrained sampling; unknown keywords are preserved in ``extra`` so a
/// decode/encode round-trip does not lose information.
public struct JSONSchema: Sendable, Hashable {
    /// A single `type` encodes as a string, several as an array.
    public var type: [JSONSchemaType]?
    public var title: String?
    public var description: String?
    public var properties: [String: JSONSchema]?
    public var required: [String]?
    public var additionalProperties: JSONSchemaAdditionalProperties?
    /// Draft-2020 tuple items (`prefixItems`).
    public var prefixItems: [JSONSchema]?
    public var enumValues: [JSONValue]?
    public var const: JSONValue?
    public var defaultValue: JSONValue?
    public var format: String?
    public var minimum: Double?
    public var maximum: Double?
    public var exclusiveMinimum: Double?
    public var exclusiveMaximum: Double?
    public var multipleOf: Double?
    public var minLength: Int?
    public var maxLength: Int?
    public var pattern: String?
    public var minItems: Int?
    public var maxItems: Int?
    public var uniqueItems: Bool?
    public var minProperties: Int?
    public var maxProperties: Int?
    public var anyOf: [JSONSchema]?
    public var oneOf: [JSONSchema]?
    public var allOf: [JSONSchema]?
    public var ref: String?
    public var definitions: [String: JSONSchema]?
    /// Unknown keywords preserved verbatim.
    public var extra: JSONObject?

    /// Nested schema for the single-schema `items` form.
    public var items: JSONSchema? {
        get { itemsBox?.schema }
        set { itemsBox = newValue.map(JSONSchemaBox.init) }
    }

    /// Nested schema for the `not` keyword.
    public var not: JSONSchema? {
        get { notBox?.schema }
        set { notBox = newValue.map(JSONSchemaBox.init) }
    }

    private var itemsBox: JSONSchemaBox?
    private var notBox: JSONSchemaBox?

    public init(
        type: [JSONSchemaType]? = nil,
        title: String? = nil,
        description: String? = nil,
        properties: [String: JSONSchema]? = nil,
        required: [String]? = nil,
        additionalProperties: JSONSchemaAdditionalProperties? = nil,
        items: JSONSchema? = nil,
        prefixItems: [JSONSchema]? = nil,
        enumValues: [JSONValue]? = nil,
        const: JSONValue? = nil,
        defaultValue: JSONValue? = nil,
        format: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        exclusiveMinimum: Double? = nil,
        exclusiveMaximum: Double? = nil,
        multipleOf: Double? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        pattern: String? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        uniqueItems: Bool? = nil,
        minProperties: Int? = nil,
        maxProperties: Int? = nil,
        anyOf: [JSONSchema]? = nil,
        oneOf: [JSONSchema]? = nil,
        allOf: [JSONSchema]? = nil,
        not: JSONSchema? = nil,
        ref: String? = nil,
        definitions: [String: JSONSchema]? = nil,
        extra: JSONObject? = nil
    ) {
        self.type = type
        self.title = title
        self.description = description
        self.properties = properties
        self.required = required
        self.additionalProperties = additionalProperties
        self.itemsBox = items.map(JSONSchemaBox.init)
        self.prefixItems = prefixItems
        self.enumValues = enumValues
        self.const = const
        self.defaultValue = defaultValue
        self.format = format
        self.minimum = minimum
        self.maximum = maximum
        self.exclusiveMinimum = exclusiveMinimum
        self.exclusiveMaximum = exclusiveMaximum
        self.multipleOf = multipleOf
        self.minLength = minLength
        self.maxLength = maxLength
        self.pattern = pattern
        self.minItems = minItems
        self.maxItems = maxItems
        self.uniqueItems = uniqueItems
        self.minProperties = minProperties
        self.maxProperties = maxProperties
        self.anyOf = anyOf
        self.oneOf = oneOf
        self.allOf = allOf
        self.notBox = not.map(JSONSchemaBox.init)
        self.ref = ref
        self.definitions = definitions
        self.extra = extra
    }
}

// MARK: - Convenience accessors

extension JSONSchema {
    /// The single `type` value when exactly one type is declared.
    public var singleType: JSONSchemaType? {
        guard let type, type.count == 1 else { return nil }
        return type[0]
    }

    public var isObject: Bool { type?.contains(.object) ?? false }
    public var isArray: Bool { type?.contains(.array) ?? false }
}

// MARK: - Codable

extension JSONSchema: Codable {
    private enum Key {
        static let type = "type"
        static let title = "title"
        static let description = "description"
        static let properties = "properties"
        static let required = "required"
        static let additionalProperties = "additionalProperties"
        static let items = "items"
        static let prefixItems = "prefixItems"
        static let enumValues = "enum"
        static let const = "const"
        static let defaultValue = "default"
        static let format = "format"
        static let minimum = "minimum"
        static let maximum = "maximum"
        static let exclusiveMinimum = "exclusiveMinimum"
        static let exclusiveMaximum = "exclusiveMaximum"
        static let multipleOf = "multipleOf"
        static let minLength = "minLength"
        static let maxLength = "maxLength"
        static let pattern = "pattern"
        static let minItems = "minItems"
        static let maxItems = "maxItems"
        static let uniqueItems = "uniqueItems"
        static let minProperties = "minProperties"
        static let maxProperties = "maxProperties"
        static let anyOf = "anyOf"
        static let oneOf = "oneOf"
        static let allOf = "allOf"
        static let not = "not"
        static let ref = "$ref"
        static let defs = "$defs"
        static let definitions = "definitions"

        static let all: Set<String> = [
            type, title, description, properties, required, additionalProperties,
            items, prefixItems, enumValues, const, defaultValue, format,
            minimum, maximum, exclusiveMinimum, exclusiveMaximum, multipleOf,
            minLength, maxLength, pattern, minItems, maxItems, uniqueItems,
            minProperties, maxProperties, anyOf, oneOf, allOf, not, ref, defs, definitions,
        ]
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        try self.init(jsonValue: value)
    }

    public func encode(to encoder: Encoder) throws {
        try makeJSONValue().encode(to: encoder)
    }
}

// MARK: - JSONValue mapping

extension JSONSchema {
    /// Builds a schema from a raw JSON object.
    public init(jsonValue: JSONValue) throws {
        guard let object = jsonValue.objectValue else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "JSON Schema must be an object")
            )
        }
        self.init()
        for (key, value) in object {
            switch key {
            case Key.type:
                self.type = try Self.decodeType(value)
            case Key.title:
                title = value.stringValue
            case Key.description:
                description = value.stringValue
            case Key.properties:
                properties = try Self.decodeSchemaMap(value, key: key)
            case Key.required:
                required = value.arrayValue?.compactMap(\.stringValue)
            case Key.additionalProperties:
                additionalProperties = try Self.decodeAdditionalProperties(value)
            case Key.items:
                if case .array(let schemas) = value {
                    prefixItems = try schemas.map { try JSONSchema(jsonValue: $0) }
                } else {
                    items = try JSONSchema(jsonValue: value)
                }
            case Key.prefixItems:
                prefixItems = try Self.decodeSchemaArray(value, key: key)
            case Key.enumValues:
                enumValues = value.arrayValue
            case Key.const:
                const = value
            case Key.defaultValue:
                defaultValue = value
            case Key.format:
                format = value.stringValue
            case Key.minimum:
                minimum = value.doubleValue
            case Key.maximum:
                maximum = value.doubleValue
            case Key.exclusiveMinimum:
                exclusiveMinimum = value.doubleValue
            case Key.exclusiveMaximum:
                exclusiveMaximum = value.doubleValue
            case Key.multipleOf:
                multipleOf = value.doubleValue
            case Key.minLength:
                minLength = value.intValue
            case Key.maxLength:
                maxLength = value.intValue
            case Key.pattern:
                pattern = value.stringValue
            case Key.minItems:
                minItems = value.intValue
            case Key.maxItems:
                maxItems = value.intValue
            case Key.uniqueItems:
                uniqueItems = value.boolValue
            case Key.minProperties:
                minProperties = value.intValue
            case Key.maxProperties:
                maxProperties = value.intValue
            case Key.anyOf:
                anyOf = try Self.decodeSchemaArray(value, key: key)
            case Key.oneOf:
                oneOf = try Self.decodeSchemaArray(value, key: key)
            case Key.allOf:
                allOf = try Self.decodeSchemaArray(value, key: key)
            case Key.not:
                not = try JSONSchema(jsonValue: value)
            case Key.ref:
                ref = value.stringValue
            case Key.defs, Key.definitions:
                definitions = try Self.decodeSchemaMap(value, key: key)
            default:
                if extra == nil { extra = [:] }
                extra?[key] = value
            }
        }
    }

    /// Renders the schema back into a raw JSON object.
    public func makeJSONValue() -> JSONValue {
        var object: JSONObject = extra ?? [:]

        if let type {
            if type.count == 1 {
                object[Key.type] = .string(type[0].rawValue)
            } else {
                object[Key.type] = .array(type.map { .string($0.rawValue) })
            }
        }
        if let title { object[Key.title] = .string(title) }
        if let description { object[Key.description] = .string(description) }
        if let properties {
            object[Key.properties] = .object(properties.mapValues { $0.makeJSONValue() })
        }
        if let required { object[Key.required] = .array(required.map { .string($0) }) }
        if let additionalProperties {
            switch additionalProperties {
            case .bool(let value): object[Key.additionalProperties] = .bool(value)
            case .schema(let schema): object[Key.additionalProperties] = schema.makeJSONValue()
            }
        }
        if let items { object[Key.items] = items.makeJSONValue() }
        if let prefixItems {
            object[Key.prefixItems] = .array(prefixItems.map { $0.makeJSONValue() })
        }
        if let enumValues { object[Key.enumValues] = .array(enumValues) }
        if let const { object[Key.const] = const }
        if let defaultValue { object[Key.defaultValue] = defaultValue }
        if let format { object[Key.format] = .string(format) }
        if let minimum { object[Key.minimum] = .number(minimum) }
        if let maximum { object[Key.maximum] = .number(maximum) }
        if let exclusiveMinimum { object[Key.exclusiveMinimum] = .number(exclusiveMinimum) }
        if let exclusiveMaximum { object[Key.exclusiveMaximum] = .number(exclusiveMaximum) }
        if let multipleOf { object[Key.multipleOf] = .number(multipleOf) }
        if let minLength { object[Key.minLength] = .int(minLength) }
        if let maxLength { object[Key.maxLength] = .int(maxLength) }
        if let pattern { object[Key.pattern] = .string(pattern) }
        if let minItems { object[Key.minItems] = .int(minItems) }
        if let maxItems { object[Key.maxItems] = .int(maxItems) }
        if let uniqueItems { object[Key.uniqueItems] = .bool(uniqueItems) }
        if let minProperties { object[Key.minProperties] = .int(minProperties) }
        if let maxProperties { object[Key.maxProperties] = .int(maxProperties) }
        if let anyOf { object[Key.anyOf] = .array(anyOf.map { $0.makeJSONValue() }) }
        if let oneOf { object[Key.oneOf] = .array(oneOf.map { $0.makeJSONValue() }) }
        if let allOf { object[Key.allOf] = .array(allOf.map { $0.makeJSONValue() }) }
        if let not { object[Key.not] = not.makeJSONValue() }
        if let ref { object[Key.ref] = .string(ref) }
        if let definitions { object[Key.defs] = .object(definitions.mapValues { $0.makeJSONValue() }) }

        return .object(object)
    }

    private static func decodeType(_ value: JSONValue) throws -> [JSONSchemaType] {
        if let string = value.stringValue {
            guard let type = JSONSchemaType(rawValue: string) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Unknown JSON Schema type: \(string)")
                )
            }
            return [type]
        }
        if let array = value.arrayValue {
            return try array.map { element in
                guard let string = element.stringValue, let type = JSONSchemaType(rawValue: string) else {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: [], debugDescription: "Unknown JSON Schema type: \(element)")
                    )
                }
                return type
            }
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "`type` must be a string or array of strings")
        )
    }

    private static func decodeSchemaMap(_ value: JSONValue, key: String) throws -> [String: JSONSchema] {
        guard let object = value.objectValue else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "`\(key)` must be an object of schemas")
            )
        }
        return try object.mapValues { try JSONSchema(jsonValue: $0) }
    }

    private static func decodeSchemaArray(_ value: JSONValue, key: String) throws -> [JSONSchema] {
        guard let array = value.arrayValue else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "`\(key)` must be an array of schemas")
            )
        }
        return try array.map { try JSONSchema(jsonValue: $0) }
    }

    private static func decodeAdditionalProperties(_ value: JSONValue) throws -> JSONSchemaAdditionalProperties {
        if let bool = value.boolValue { return .bool(bool) }
        return .schema(try JSONSchema(jsonValue: value))
    }
}

// MARK: - Builders

extension JSONSchema {
    public static func string(
        description: String? = nil,
        enumValues: [String]? = nil,
        format: String? = nil
    ) -> JSONSchema {
        JSONSchema(
            type: [.string],
            description: description,
            enumValues: enumValues.map { $0.map { .string($0) } },
            format: format
        )
    }

    public static func integer(
        description: String? = nil,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> JSONSchema {
        JSONSchema(
            type: [.integer],
            description: description,
            minimum: minimum.map(Double.init),
            maximum: maximum.map(Double.init)
        )
    }

    public static func number(
        description: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) -> JSONSchema {
        JSONSchema(type: [.number], description: description, minimum: minimum, maximum: maximum)
    }

    public static func boolean(description: String? = nil) -> JSONSchema {
        JSONSchema(type: [.boolean], description: description)
    }

    public static func array(items: JSONSchema, description: String? = nil) -> JSONSchema {
        JSONSchema(type: [.array], description: description, items: items)
    }

    public static func object(
        properties: [String: JSONSchema] = [:],
        required: [String] = [],
        additionalProperties: Bool = false,
        description: String? = nil
    ) -> JSONSchema {
        JSONSchema(
            type: [.object],
            description: description,
            properties: properties,
            required: required,
            additionalProperties: .bool(additionalProperties)
        )
    }
}
