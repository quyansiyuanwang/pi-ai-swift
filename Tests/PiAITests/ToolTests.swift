import Foundation
import Testing
@testable import PiAI

@Suite struct ToolTests {
    @Test func toolRoundTrip() throws {
        let tool = Tool(
            name: "get_weather",
            description: "Get the weather",
            parameters: .object(
                properties: ["location": .string(description: "City")],
                required: ["location"],
                additionalProperties: false
            )
        )
        let value = try TestSupport.encodeToJSONValue(tool)
        #expect(value["name"] == .string("get_weather"))
        #expect(value["parameters"]["type"] == .string("object"))
        #expect(value["constrainedSampling"].isNull)
        #expect(try TestSupport.roundTrip(tool) == tool)
    }

    @Test func jsonSchemaConstrainedSamplingRoundTrip() throws {
        let sampling = ConstrainedSampling.jsonSchema(strict: .require)
        let value = try TestSupport.encodeToJSONValue(sampling)
        #expect(value["type"] == .string("json_schema"))
        #expect(value["strict"] == .string("require"))
        #expect(try TestSupport.decode(ConstrainedSampling.self, from: value) == sampling)

        let prefer = ConstrainedSampling.jsonSchema(strict: .prefer)
        #expect(try TestSupport.roundTrip(prefer) == prefer)
    }

    @Test func grammarConstrainedSamplingRoundTrip() throws {
        let sampling = ConstrainedSampling.grammar(variants: [
            "openai_lark": "start: /[a-z]+/",
            "openai_regex": "[a-z]+",
        ])
        let value = try TestSupport.encodeToJSONValue(sampling)
        #expect(value["type"] == .string("grammar"))
        #expect(value["variants"]["openai_regex"] == .string("[a-z]+"))
        #expect(try TestSupport.decode(ConstrainedSampling.self, from: value) == sampling)
    }

    @Test func disabledConstrainedSamplingRoundTrip() throws {
        let value = try TestSupport.encodeToJSONValue(ConstrainedSampling.disabled)
        #expect(value == .bool(false))
        #expect(try TestSupport.decode(ConstrainedSampling.self, from: value) == .disabled)
    }

    @Test func toolWithConstrainedSamplingRoundTrip() throws {
        let tool = Tool(
            name: "spin",
            description: "Spin",
            parameters: .object(
                properties: ["turns": .integer(minimum: 1)],
                required: ["turns"],
                additionalProperties: false
            ),
            constrainedSampling: .jsonSchema(strict: .require)
        )
        #expect(try TestSupport.roundTrip(tool) == tool)
    }
}
