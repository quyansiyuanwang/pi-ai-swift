import Foundation
import Testing
@testable import PiAI

@Suite struct JSONSchemaTests {
    @Test func objectBuilderEncodesExpectedJSON() throws {
        let schema = JSONSchema.object(
            properties: [
                "location": .string(description: "City name"),
                "days": .integer(minimum: 1, maximum: 10),
            ],
            required: ["location"],
            additionalProperties: false,
            description: "Weather query"
        )

        let value = try TestSupport.encodeToJSONValue(schema)
        #expect(value["type"] == .string("object"))
        #expect(value["description"] == .string("Weather query"))
        #expect(value["required"] == .array([.string("location")]))
        #expect(value["additionalProperties"] == .bool(false))
        #expect(value["properties"]["location"]["type"] == .string("string"))
        #expect(value["properties"]["location"]["description"] == .string("City name"))
        #expect(value["properties"]["days"]["type"] == .string("integer"))
        #expect(value["properties"]["days"]["minimum"] == .int(1))
        #expect(value["properties"]["days"]["maximum"] == .int(10))
    }

    @Test func objectBuilderRoundTrip() throws {
        let schema = JSONSchema.object(
            properties: ["location": .string(), "days": .integer(minimum: 1)],
            required: ["location"],
            additionalProperties: true,
            description: "Weather"
        )
        let decoded = try TestSupport.roundTrip(schema)
        #expect(decoded == schema)
    }

    @Test func singleTypeEncodesAsStringAndMultipleAsArray() throws {
        let single = JSONSchema(type: [.object])
        let singleValue = try TestSupport.encodeToJSONValue(single)
        #expect(singleValue["type"] == .string("object"))
        #expect(single.singleType == .object)

        let multiple = JSONSchema(type: [.string, .null])
        let multipleValue = try TestSupport.encodeToJSONValue(multiple)
        #expect(multipleValue["type"] == .array([.string("string"), .string("null")]))
        #expect(multiple.singleType == nil)
        #expect(try TestSupport.roundTrip(multiple) == multiple)
    }

    @Test func unknownKeywordIsPreserved() throws {
        let value = try TestSupport.jsonValue(fromJSON: #"{"type":"object","x-custom":42,"deprecated":true}"#)
        let schema = try JSONSchema(jsonValue: value)
        #expect(schema.extra?["x-custom"] == .int(42))
        #expect(schema.extra?["deprecated"] == .bool(true))

        let reencoded = try TestSupport.encodeToJSONValue(schema)
        #expect(reencoded["x-custom"] == .int(42))
        #expect(reencoded["deprecated"] == .bool(true))
        #expect(try JSONSchema(jsonValue: reencoded) == schema)
    }

    @Test func itemsRecursionRoundTrip() throws {
        let schema = JSONSchema.array(
            items: .object(properties: ["x": .integer()], required: ["x"], additionalProperties: false)
        )
        #expect(schema.isArray)
        #expect(schema.items?.singleType == .object)

        let value = try TestSupport.encodeToJSONValue(schema)
        #expect(value["type"] == .string("array"))
        #expect(value["items"]["type"] == .string("object"))
        #expect(try TestSupport.roundTrip(schema) == schema)
    }

    @Test func additionalPropertiesSchema() throws {
        let schema = JSONSchema(
            type: [.object],
            additionalProperties: .schema(.string())
        )
        let value = try TestSupport.encodeToJSONValue(schema)
        #expect(value["additionalProperties"]["type"] == .string("string"))
        #expect(try TestSupport.roundTrip(schema) == schema)
    }

    @Test func refAndDefinitions() throws {
        let schema = JSONSchema(
            ref: "#/$defs/Name",
            definitions: ["Name": .string(description: "A name")]
        )
        let value = try TestSupport.encodeToJSONValue(schema)
        #expect(value["$ref"] == .string("#/$defs/Name"))
        #expect(value["$defs"]["Name"]["type"] == .string("string"))
        #expect(try TestSupport.roundTrip(schema) == schema)
    }

    @Test func enumConstAndComposition() throws {
        let schema = JSONSchema(
            oneOf: [
                .string(enumValues: ["a", "b"]),
                JSONSchema(type: [.integer], const: .int(7)),
            ]
        )
        let value = try TestSupport.encodeToJSONValue(schema)
        #expect(value["oneOf"][0]["enum"] == .array([.string("a"), .string("b")]))
        #expect(value["oneOf"][1]["const"] == .int(7))
        #expect(try TestSupport.roundTrip(schema) == schema)
    }

    @Test func notAndTupleItems() throws {
        let schema = JSONSchema(
            type: [.array],
            prefixItems: [.string(), .integer()],
            not: JSONSchema(type: [.null])
        )
        let value = try TestSupport.encodeToJSONValue(schema)
        #expect(value["prefixItems"][0]["type"] == .string("string"))
        #expect(value["not"]["type"] == .string("null"))
        #expect(try TestSupport.roundTrip(schema) == schema)
    }

    @Test func numericAndStringConstraints() throws {
        let schema = JSONSchema(
            type: [.number],
            minimum: 0,
            maximum: 100,
            exclusiveMinimum: -1,
            exclusiveMaximum: 101,
            multipleOf: 0.5
        )
        let value = try TestSupport.encodeToJSONValue(schema)
        #expect(value["minimum"] == .int(0))
        #expect(value["multipleOf"] == .double(0.5))
        #expect(try TestSupport.roundTrip(schema) == schema)
    }

    @Test func decodingBooleanSchemaThrows() {
        #expect(throws: (any Error).self) {
            try JSONSchema(jsonValue: .bool(true))
        }
    }

    @Test func decodingUnknownTypeThrows() throws {
        let value = try TestSupport.jsonValue(fromJSON: #"{"type":"mystery"}"#)
        #expect(throws: (any Error).self) {
            try JSONSchema(jsonValue: value)
        }
    }
}
