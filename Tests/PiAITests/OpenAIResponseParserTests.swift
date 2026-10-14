import Foundation
import Testing
@testable import PiAI

@Suite struct OpenAIResponseParserTests {
    private func makeModel(id: String = "gpt-4o-mini", provider: String = "openai") -> Model {
        Model(
            id: id,
            name: id,
            api: "openai-completions",
            provider: provider,
            baseURL: "https://api.openai.com/v1",
            contextWindow: 128_000,
            maxTokens: 16_384
        )
    }

    private func response(
        id: String = "chatcmpl-1",
        model: String? = "gpt-4o-mini",
        message: String,
        finishReason: String? = "stop",
        usage: String? = nil
    ) -> Data {
        var fields: [String] = ["\"id\":\"\(id)\""]
        if let model { fields.append("\"model\":\"\(model)\"") }
        var choice = "\"message\":\(message)"
        if let finishReason { choice += ",\"finish_reason\":\"\(finishReason)\"" }
        fields.append("\"choices\":[{\(choice)}]")
        if let usage { fields.append("\"usage\":\(usage)") }
        let json = "{\(fields.joined(separator: ","))}"
        return Data(json.utf8)
    }

    @Test func parsesTextContent() throws {
        let data = response(message: #"{"role":"assistant","content":"hello world"}"#)
        let message = try OpenAIResponseParser.parse(data, model: makeModel())
        #expect(message.content == [.text(TextContent(text: "hello world"))])
        #expect(message.stopReason == .stop)
        #expect(message.responseId == "chatcmpl-1")
        #expect(message.rawStopReason == "stop")
        #expect(message.api == "openai-completions")
        #expect(message.provider == "openai")
        #expect(message.model == "gpt-4o-mini")
    }

    @Test func parsesReasoningContent() throws {
        let data = response(message: #"{"content":"answer","reasoning_content":"thinking hard"}"#)
        let message = try OpenAIResponseParser.parse(data, model: makeModel())
        #expect(message.content.count == 2)
        #expect(message.content[0] == .thinking(ThinkingContent(thinking: "thinking hard", thinkingSignature: "reasoning_content")))
        #expect(message.content[1] == .text(TextContent(text: "answer")))
    }

    @Test func parsesReasoningFieldName() throws {
        let data = response(message: #"{"content":"answer","reasoning":"thinking"}"#)
        let message = try OpenAIResponseParser.parse(data, model: makeModel())
        #expect(message.content[0] == .thinking(ThinkingContent(thinking: "thinking", thinkingSignature: "reasoning")))
    }

    @Test func parsesReasoningTextFieldName() throws {
        let data = response(message: #"{"content":"answer","reasoning_text":"thinking"}"#)
        let message = try OpenAIResponseParser.parse(data, model: makeModel())
        #expect(message.content[0] == .thinking(ThinkingContent(thinking: "thinking", thinkingSignature: "reasoning_text")))
    }

    @Test func prefersReasoningContentOverOtherFields() throws {
        let data = response(message: #"{"reasoning_content":"primary","reasoning":"secondary"}"#)
        let message = try OpenAIResponseParser.parse(data, model: makeModel())
        #expect(message.content.count == 1)
        #expect(message.content[0] == .thinking(ThinkingContent(thinking: "primary", thinkingSignature: "reasoning_content")))
    }

    @Test func parsesToolCallsWithArguments() throws {
        let message = #"""
        {"content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"swift\"}"}}]}
        """#
        let data = response(message: message, finishReason: "tool_calls")
        let parsed = try OpenAIResponseParser.parse(data, model: makeModel())
        #expect(parsed.stopReason == .toolUse)
        #expect(parsed.content.count == 1)
        #expect(parsed.content[0] == .toolCall(ToolCall(id: "call_1", name: "lookup", arguments: ["q": "swift"])))
    }

    @Test func malformedToolArgumentsFallBackToEmptyObject() throws {
        let message = #"{"tool_calls":[{"id":"call_1","function":{"name":"lookup","arguments":"not json"}}]}"#
        let data = response(message: message, finishReason: "tool_calls")
        let parsed = try OpenAIResponseParser.parse(data, model: makeModel())
        #expect(parsed.content[0] == .toolCall(ToolCall(id: "call_1", name: "lookup", arguments: [:])))
    }

    @Test func emptyToolArgumentsFallBackToEmptyObject() throws {
        let message = #"{"tool_calls":[{"id":"call_1","function":{"name":"lookup","arguments":""}}]}"#
        let data = response(message: message, finishReason: "tool_calls")
        let parsed = try OpenAIResponseParser.parse(data, model: makeModel())
        #expect(parsed.content[0] == .toolCall(ToolCall(id: "call_1", name: "lookup", arguments: [:])))
    }

    @Test func mapsFinishReasons() {
        let cases: [(String?, StopReason, String?)] = [
            (nil, .stop, nil),
            ("stop", .stop, nil),
            ("end", .stop, nil),
            ("length", .length, nil),
            ("function_call", .toolUse, nil),
            ("tool_calls", .toolUse, nil),
            ("content_filter", .error, "Provider finish_reason: content_filter"),
            ("network_error", .error, "Provider finish_reason: network_error"),
            ("something_else", .error, "Provider finish_reason: something_else"),
        ]
        for (reason, expectedStop, expectedError) in cases {
            let mapped = OpenAIResponseParser.mapStopReason(reason)
            #expect(mapped.stopReason == expectedStop, "reason: \(reason ?? "nil")")
            #expect(mapped.errorMessage == expectedError, "reason: \(reason ?? "nil")")
        }
    }

    @Test func parsesUsage() throws {
        let usage = #"{"prompt_tokens":100,"completion_tokens":24,"prompt_tokens_details":{"cached_tokens":50,"cache_write_tokens":30},"completion_tokens_details":{"reasoning_tokens":8}}"#
        let data = response(message: #"{"content":"ok"}"#, usage: usage)
        let message = try OpenAIResponseParser.parse(data, model: makeModel())
        #expect(message.usage.input == 20)
        #expect(message.usage.output == 24)
        #expect(message.usage.cacheRead == 50)
        #expect(message.usage.cacheWrite == 30)
        #expect(message.usage.reasoning == 8)
        #expect(message.usage.totalTokens == 124)
        #expect(message.usage.cost == .zero)
    }

    @Test func parsesUsageFallbackCacheFields() throws {
        let usage = #"{"prompt_tokens":10,"completion_tokens":5,"prompt_cache_hit_tokens":3}"#
        let data = response(message: #"{"content":"ok"}"#, usage: usage)
        let message = try OpenAIResponseParser.parse(data, model: makeModel())
        #expect(message.usage.cacheRead == 3)
        #expect(message.usage.input == 7)
        #expect(message.usage.totalTokens == 15)
    }

    @Test func responseModelOnlyWhenDifferent() throws {
        let same = try OpenAIResponseParser.parse(
            response(model: "gpt-4o-mini", message: #"{"content":"ok"}"#),
            model: makeModel()
        )
        #expect(same.responseModel == nil)

        let routed = try OpenAIResponseParser.parse(
            response(model: "anthropic/claude-opus-4.8", message: #"{"content":"ok"}"#),
            model: makeModel(id: "openrouter/auto", provider: "openrouter")
        )
        #expect(routed.model == "openrouter/auto")
        #expect(routed.responseModel == "anthropic/claude-opus-4.8")
    }

    @Test func emptyChoicesThrows() {
        let data = Data(#"{"id":"x","choices":[]}"#.utf8)
        do {
            _ = try OpenAIResponseParser.parse(data, model: makeModel())
            Issue.record("expected emptyChoices")
        } catch let error as OpenAIResponseError {
            #expect(error == .emptyChoices)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func malformedMessageThrows() {
        let data = Data(#"{"id":"x","choices":[{"finish_reason":"stop"}]}"#.utf8)
        do {
            _ = try OpenAIResponseParser.parse(data, model: makeModel())
            Issue.record("expected malformedMessage")
        } catch let error as OpenAIResponseError {
            #expect(error == .malformedMessage)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func parseValueMatchesParseData() throws {
        let data = response(message: #"{"content":"ok"}"#)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let fromData = try OpenAIResponseParser.parse(data, model: makeModel())
        let fromValue = try OpenAIResponseParser.parse(value, model: makeModel())
        #expect(fromData.content == fromValue.content)
        #expect(fromData.stopReason == fromValue.stopReason)
        #expect(fromData.responseId == fromValue.responseId)
    }

    @Test func timestampIsRecent() throws {
        let before = Int(Date().timeIntervalSince1970 * 1000)
        let message = try OpenAIResponseParser.parse(response(message: #"{"content":"ok"}"#), model: makeModel())
        let after = Int(Date().timeIntervalSince1970 * 1000)
        #expect(message.timestamp >= before)
        #expect(message.timestamp <= after)
    }
}
