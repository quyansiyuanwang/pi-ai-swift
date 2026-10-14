import Foundation
import Testing
@testable import PiAI

@Suite struct ContentTests {
    @Test func textBlockRoundTrip() throws {
        let block = ContentBlock.text(TextContent(text: "hello", textSignature: "sig"))
        let value = try TestSupport.encodeToJSONValue(block)
        #expect(value["type"] == .string("text"))
        #expect(value["text"] == .string("hello"))
        #expect(value["textSignature"] == .string("sig"))
        #expect(try TestSupport.decode(ContentBlock.self, from: value) == block)
    }

    @Test func thinkingBlockRoundTrip() throws {
        let block = ContentBlock.thinking(
            ThinkingContent(thinking: "hmm", thinkingSignature: "opaque", redacted: true)
        )
        let value = try TestSupport.encodeToJSONValue(block)
        #expect(value["type"] == .string("thinking"))
        #expect(value["thinking"] == .string("hmm"))
        #expect(value["redacted"] == .bool(true))
        #expect(try TestSupport.decode(ContentBlock.self, from: value) == block)
    }

    @Test func imageBlockRoundTrip() throws {
        let block = ContentBlock.image(ImageContent(data: "aGVsbG8=", mimeType: "image/png"))
        let value = try TestSupport.encodeToJSONValue(block)
        #expect(value["type"] == .string("image"))
        #expect(value["mimeType"] == .string("image/png"))
        #expect(try TestSupport.decode(ContentBlock.self, from: value) == block)
    }

    @Test func toolCallBlockRoundTrip() throws {
        let call = ToolCall(
            id: "call_1",
            name: "get_weather",
            arguments: ["location": "Paris", "days": 3],
            namespace: "weather"
        )
        #expect(call.argumentsObject?["location"] == .string("Paris"))

        let block = ContentBlock.toolCall(call)
        let value = try TestSupport.encodeToJSONValue(block)
        #expect(value["type"] == .string("toolCall"))
        #expect(value["name"] == .string("get_weather"))
        #expect(value["arguments"]["days"] == .int(3))
        #expect(value["namespace"] == .string("weather"))
        #expect(try TestSupport.decode(ContentBlock.self, from: value) == block)
    }

    @Test func unknownContentTypeThrows() throws {
        let value = try TestSupport.jsonValue(fromJSON: #"{"type":"video","url":"x"}"#)
        #expect(throws: (any Error).self) {
            try TestSupport.decode(ContentBlock.self, from: value)
        }
    }

    @Test func messageContentString() throws {
        let content = MessageContent.text("hello")
        let value = try TestSupport.encodeToJSONValue(content)
        #expect(value == .string("hello"))
        #expect(try TestSupport.decode(MessageContent.self, from: value) == content)
        #expect(content.textValue == "hello")
    }

    @Test func messageContentBlocks() throws {
        let content = MessageContent.blocks([
            .text(TextContent(text: "look")),
            .image(ImageContent(data: "aGk=", mimeType: "image/jpeg")),
        ])
        let value = try TestSupport.encodeToJSONValue(content)
        #expect(value[0]["type"] == .string("text"))
        #expect(value[1]["type"] == .string("image"))
        #expect(try TestSupport.decode(MessageContent.self, from: value) == content)
        #expect(content.textValue == nil)
    }
}
