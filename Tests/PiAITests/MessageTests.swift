import Foundation
import Testing
@testable import PiAI

@Suite struct MessageTests {
    @Test func systemMessageRoundTrip() throws {
        let message = Message.system(SystemMessage(content: "You are helpful.", timestamp: 1))
        let value = try TestSupport.encodeToJSONValue(message)
        #expect(value["role"] == .string("system"))
        #expect(value["content"] == .string("You are helpful."))
        #expect(value["timestamp"] == .int(1))
        #expect(try TestSupport.decode(Message.self, from: value) == message)
        #expect(message.role == "system")
    }

    @Test func userTextMessageRoundTrip() throws {
        let message = Message.user(UserMessage(content: "Hi", timestamp: 2))
        let value = try TestSupport.encodeToJSONValue(message)
        #expect(value["role"] == .string("user"))
        #expect(value["content"] == .string("Hi"))
        #expect(try TestSupport.decode(Message.self, from: value) == message)
    }

    @Test func userBlockMessageRoundTrip() throws {
        let message = Message.user(
            UserMessage(
                content: .blocks([
                    .text(TextContent(text: "describe")),
                    .image(ImageContent(data: "aGk=", mimeType: "image/png")),
                ]),
                timestamp: 3
            )
        )
        let value = try TestSupport.encodeToJSONValue(message)
        #expect(value["content"][0]["type"] == .string("text"))
        #expect(value["content"][1]["type"] == .string("image"))
        #expect(try TestSupport.decode(Message.self, from: value) == message)
    }

    @Test func assistantMessageRoundTrip() throws {
        let message = Message.assistant(
            AssistantMessage(
                content: [
                    .thinking(ThinkingContent(thinking: "plan")),
                    .text(TextContent(text: "calling tool")),
                    .toolCall(ToolCall(id: "call_1", name: "lookup", arguments: ["q": "swift"])),
                ],
                api: "openai-completions",
                provider: "openai",
                model: "gpt-4o",
                responseModel: "gpt-4o-2024-08-06",
                responseId: "resp_123",
                usage: Usage(input: 10, output: 5, totalTokens: 15),
                stopReason: .toolUse,
                timestamp: 4
            )
        )
        let value = try TestSupport.encodeToJSONValue(message)
        #expect(value["role"] == .string("assistant"))
        #expect(value["stopReason"] == .string("toolUse"))
        #expect(value["usage"]["totalTokens"] == .int(15))
        #expect(value["content"][2]["arguments"]["q"] == .string("swift"))
        #expect(try TestSupport.decode(Message.self, from: value) == message)
    }

    @Test func assistantMessageWithOnlyToolCallsRoundTrip() throws {
        let message = Message.assistant(
            AssistantMessage(
                content: [.toolCall(ToolCall(id: "call_1", name: "lookup"))],
                stopReason: .toolUse,
                timestamp: 5
            )
        )
        let value = try TestSupport.encodeToJSONValue(message)
        #expect(value["content"].arrayValue?.count == 1)
        #expect(value["content"][0]["type"] == .string("toolCall"))
        #expect(try TestSupport.decode(Message.self, from: value) == message)
    }

    @Test func toolResultMessageRoundTrip() throws {
        let message = Message.toolResult(
            ToolResultMessage(
                toolCallId: "call_1",
                toolName: "lookup",
                content: [.text(TextContent(text: "Paris"))],
                details: ["temperature": 18],
                usage: Usage(input: 1, output: 1, totalTokens: 2),
                isError: false,
                timestamp: 6
            )
        )
        let value = try TestSupport.encodeToJSONValue(message)
        #expect(value["role"] == .string("toolResult"))
        #expect(value["toolCallId"] == .string("call_1"))
        #expect(value["details"]["temperature"] == .int(18))
        #expect(value["isError"] == .bool(false))
        #expect(try TestSupport.decode(Message.self, from: value) == message)
    }

    @Test func unknownRoleThrows() throws {
        let value = try TestSupport.jsonValue(fromJSON: #"{"role":"developer","content":"hi"}"#)
        #expect(throws: (any Error).self) {
            try TestSupport.decode(Message.self, from: value)
        }
    }

    @Test func missingRoleThrows() throws {
        let value = try TestSupport.jsonValue(fromJSON: #"{"content":"hi"}"#)
        #expect(throws: (any Error).self) {
            try TestSupport.decode(Message.self, from: value)
        }
    }
}
