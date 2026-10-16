import Foundation
import Testing
@testable import PiAI

@Suite struct AnthropicMessagesTests {
    // MARK: - Helpers

    private func makeModel(
        id: String = "claude-sonnet-4",
        provider: String = "anthropic",
        baseURL: String = "https://api.anthropic.com",
        api: String = "anthropic-messages",
        maxTokens: Int = 8192
    ) -> Model {
        Model(
            id: id,
            name: id,
            api: api,
            provider: provider,
            baseURL: baseURL,
            contextWindow: 200_000,
            maxTokens: maxTokens,
            reasoning: true,
            input: [.text, .image]
        )
    }

    private func makeProvider(
        maxRetries: Int = 0,
        reasoningBudgetTokens: Int? = nil
    ) -> AnthropicMessagesProvider {
        AnthropicMessagesProvider(
            httpClient: URLSessionHTTPClient(configuration: MockURLProtocol.makeConfiguration()),
            maxRetries: maxRetries,
            reasoningBudgetTokens: reasoningBudgetTokens
        )
    }

    /// Serializes an event object as an SSE `data:` frame.
    private func sse(_ object: JSONObject) -> Data {
        let data = (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data()
        return Data("data: \(String(decoding: data, as: UTF8.self))\n\n".utf8)
    }

    private func event(_ type: String, _ extra: JSONObject = [:]) -> Data {
        var object = extra
        object["type"] = .string(type)
        return sse(object)
    }

    private func messageStart(
        id: String = "msg_1",
        model: String = "claude-sonnet-4",
        usage: JSONObject
    ) -> Data {
        event("message_start", [
            "message": .object([
                "id": .string(id),
                "type": .string("message"),
                "role": .string("assistant"),
                "model": .string(model),
                "content": .array([]),
                "stop_reason": .null,
                "usage": .object(usage),
            ]),
        ])
    }

    private func context(_ messages: [Message] = []) -> ChatContext {
        ChatContext(messages: messages)
    }

    private final class Recorder: @unchecked Sendable {
        var started = false
        var text = ""
        var thinking = ""
        var toolCallDeltas: [(index: Int, id: String?, name: String?, fragment: String)] = []
        var done: AssistantMessage?
        var error: (any Error)?
        var thrown: (any Error)?

        func consume(_ event: AssistantMessageEvent) {
            switch event {
            case .start:
                started = true
            case .textDelta(let delta):
                text += delta
            case .thinkingDelta(let delta):
                thinking += delta
            case .toolCallDelta(let index, let id, let name, let fragment):
                toolCallDeltas.append((index, id, name, fragment))
            case .done(let message):
                done = message
            case .error(let error):
                self.error = error
            }
        }
    }

    private func run(_ stream: AsyncThrowingStream<AssistantMessageEvent, any Error>) async -> Recorder {
        let recorder = Recorder()
        do {
            for try await event in stream {
                recorder.consume(event)
            }
        } catch {
            recorder.thrown = error
        }
        return recorder
    }

    // MARK: - Request building

    @Test func sendsExpectedRequest() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(#"""
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-4","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """#))
        let provider = makeProvider(reasoningBudgetTokens: 2048)
        _ = try await provider.complete(
            model: makeModel(baseURL: endpoint.baseURL),
            context: ChatContext(
                systemPrompt: "be helpful",
                messages: [.user(UserMessage(content: "hi", timestamp: 0))],
                tools: [
                    Tool(
                        name: "lookup",
                        description: "Look something up",
                        parameters: .object(properties: ["q": .string()], required: ["q"])
                    ),
                ]
            ),
            options: ChatOptions(apiKey: "test", temperature: 0.4, maxTokens: 1234, topP: 0.9)
        )

        let request = try #require(endpoint.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "\(endpoint.baseURL)/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        #expect(body["model"] == .string("claude-sonnet-4"))
        #expect(body["max_tokens"] == .int(1234))
        #expect(body["stream"] == .bool(false))
        #expect(body["temperature"] == .number(0.4))
        #expect(body["top_p"] == .number(0.9))
        #expect(body["thinking"]["type"] == .string("enabled"))
        #expect(body["thinking"]["budget_tokens"] == .int(2048))
        #expect(body["system"] == .array([
            .object(["type": .string("text"), "text": .string("be helpful")]),
        ]))
        #expect(body["messages"][0]["role"] == .string("user"))
        #expect(body["messages"][0]["content"][0]["type"] == .string("text"))
        #expect(body["messages"][0]["content"][0]["text"] == .string("hi"))
        #expect(body["tools"][0]["name"] == .string("lookup"))
        #expect(body["tools"][0]["description"] == .string("Look something up"))
        #expect(body["tools"][0]["input_schema"]["type"] == .string("object"))
        #expect(body["tools"][0]["input_schema"]["required"] == .array([.string("q")]))
    }

    @Test func resolvesMessagesURLWithoutDuplicatingV1() throws {
        #expect(
            try AnthropicMessagesRequestBuilder.resolveURL(baseURL: "https://api.anthropic.com").absoluteString
                == "https://api.anthropic.com/v1/messages"
        )
        #expect(
            try AnthropicMessagesRequestBuilder.resolveURL(baseURL: "https://api.anthropic.com/").absoluteString
                == "https://api.anthropic.com/v1/messages"
        )
        #expect(
            try AnthropicMessagesRequestBuilder.resolveURL(baseURL: "https://api.anthropic.com/v1").absoluteString
                == "https://api.anthropic.com/v1/messages"
        )
        #expect(
            try AnthropicMessagesRequestBuilder.resolveURL(baseURL: "https://api.anthropic.com/v1/messages").absoluteString
                == "https://api.anthropic.com/v1/messages"
        )
    }

    @Test func maxTokensDefaultsToDocumentedValue() {
        let body = AnthropicMessagesRequestBuilder.makeBody(
            model: makeModel(maxTokens: 8192),
            context: context(),
            options: ChatOptions()
        )
        #expect(body["max_tokens"] == .int(4096))
    }

    @Test func thinkingOmittedWhenBudgetNotConfigured() {
        let body = AnthropicMessagesRequestBuilder.makeBody(
            model: makeModel(),
            context: context(),
            options: ChatOptions()
        )
        #expect(body["thinking"].isNull)
    }

    // MARK: - Message conversion

    @Test func systemMessagesAreFoldedIntoTopLevelSystem() {
        let body = AnthropicMessagesRequestBuilder.makeBody(
            model: makeModel(),
            context: ChatContext(
                systemPrompt: "first",
                messages: [.system(SystemMessage(content: "second", timestamp: 0))]
            ),
            options: ChatOptions()
        )
        #expect(body["system"] == .array([
            .object(["type": .string("text"), "text": .string("first")]),
            .object(["type": .string("text"), "text": .string("second")]),
        ]))
        #expect(body["messages"].arrayValue?.isEmpty == true)
    }

    @Test func userTextAndImageConversion() {
        let body = AnthropicMessagesRequestBuilder.makeBody(
            model: makeModel(),
            context: context([
                .user(UserMessage(
                    content: .blocks([
                        .text(TextContent(text: "describe")),
                        .image(ImageContent(data: "aGk=", mimeType: "image/png")),
                    ]),
                    timestamp: 0
                )),
            ]),
            options: ChatOptions()
        )
        let content = body["messages"][0]["content"]
        #expect(body["messages"][0]["role"] == .string("user"))
        #expect(content[0]["type"] == .string("text"))
        #expect(content[0]["text"] == .string("describe"))
        #expect(content[1]["type"] == .string("image"))
        #expect(content[1]["source"]["type"] == .string("base64"))
        #expect(content[1]["source"]["media_type"] == .string("image/png"))
        #expect(content[1]["source"]["data"] == .string("aGk="))
    }

    @Test func assistantTextAndToolCallConversion() {
        let body = AnthropicMessagesRequestBuilder.makeBody(
            model: makeModel(),
            context: context([
                .assistant(AssistantMessage(
                    content: [
                        .text(TextContent(text: "answer")),
                        .toolCall(ToolCall(id: "call_1", name: "lookup", arguments: ["q": "swift"])),
                    ],
                    stopReason: .toolUse,
                    timestamp: 0
                )),
            ]),
            options: ChatOptions()
        )

        let message = body["messages"][0]
        #expect(message["role"] == .string("assistant"))
        #expect(message["content"][0]["type"] == .string("text"))
        #expect(message["content"][0]["text"] == .string("answer"))
        #expect(message["content"][1]["type"] == .string("tool_use"))
        #expect(message["content"][1]["id"] == .string("call_1"))
        #expect(message["content"][1]["name"] == .string("lookup"))
        #expect(message["content"][1]["input"] == .object(["q": .string("swift")]))
    }

    @Test func consecutiveToolResultsAreGrouped() {
        let body = AnthropicMessagesRequestBuilder.makeBody(
            model: makeModel(),
            context: context([
                .toolResult(ToolResultMessage(toolCallId: "call_1", toolName: "a", text: "one", timestamp: 0)),
                .toolResult(ToolResultMessage(toolCallId: "call_2", toolName: "b", text: "two", timestamp: 1)),
            ]),
            options: ChatOptions()
        )
        #expect(body["messages"].arrayValue?.count == 1)
        let message = body["messages"][0]
        #expect(message["role"] == .string("user"))
        #expect(message["content"][0]["type"] == .string("tool_result"))
        #expect(message["content"][0]["tool_use_id"] == .string("call_1"))
        #expect(message["content"][0]["content"] == .string("one"))
        #expect(message["content"][1]["tool_use_id"] == .string("call_2"))
        #expect(message["content"][1]["content"] == .string("two"))
    }

    @Test func errorToolResultMarksImageOmitted() {
        let body = AnthropicMessagesRequestBuilder.makeBody(
            model: makeModel(),
            context: context([
                .toolResult(ToolResultMessage(
                    toolCallId: "call_1",
                    toolName: "a",
                    content: [.image(ImageContent(data: "aGk=", mimeType: "image/png"))],
                    isError: true,
                    timestamp: 0
                )),
            ]),
            options: ChatOptions()
        )
        let result = body["messages"][0]["content"][0]
        #expect(result["is_error"] == .bool(true))
        #expect(result["content"] == .string("[image omitted: error tool results cannot contain images]"))
    }

    @Test func normalizesToolCallIds() {
        #expect(AnthropicMessagesRequestBuilder.normalizeToolCallId("call.1:bad/id") == "call_1_bad_id")
        #expect(AnthropicMessagesRequestBuilder.normalizeToolCallId(String(repeating: "a", count: 70)).count == 64)
    }

    // MARK: - Streaming

    @Test func streamsTextDeltasAndUsage() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            messageStart(usage: [
                "input_tokens": .int(12),
                "output_tokens": .int(1),
                "cache_read_input_tokens": .int(3),
            ]),
            event("content_block_start", [
                "index": .int(0),
                "content_block": .object(["type": .string("text"), "text": .string("")]),
            ]),
            event("content_block_delta", [
                "index": .int(0),
                "delta": .object(["type": .string("text_delta"), "text": .string("Hel")]),
            ]),
            event("content_block_delta", [
                "index": .int(0),
                "delta": .object(["type": .string("text_delta"), "text": .string("lo")]),
            ]),
            event("content_block_stop", ["index": .int(0)]),
            event("message_delta", [
                "delta": .object(["stop_reason": .string("end_turn")]),
                "usage": .object([
                    "output_tokens": .int(4),
                    "output_tokens_details": .object(["thinking_tokens": .int(2)]),
                ]),
            ]),
            event("message_stop"),
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context([.user(UserMessage(content: "hi", timestamp: 0))]),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.started)
        #expect(recorder.thrown == nil)
        #expect(recorder.error == nil)
        #expect(recorder.text == "Hello")
        let done = try #require(recorder.done)
        #expect(done.content == [.text(TextContent(text: "Hello"))])
        #expect(done.stopReason == .stop)
        #expect(done.api == "anthropic-messages")
        #expect(done.provider == "anthropic")
        #expect(done.model == "claude-sonnet-4")
        #expect(done.responseId == "msg_1")
        #expect(done.usage.input == 12)
        #expect(done.usage.output == 4)
        #expect(done.usage.cacheRead == 3)
        #expect(done.usage.reasoning == 2)
        #expect(done.usage.totalTokens == 19)
    }

    @Test func streamsThinkingDeltasAndSignature() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            messageStart(usage: ["input_tokens": .int(5), "output_tokens": .int(1)]),
            event("content_block_start", [
                "index": .int(0),
                "content_block": .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("")]),
            ]),
            event("content_block_delta", [
                "index": .int(0),
                "delta": .object(["type": .string("thinking_delta"), "thinking": .string("think ")]),
            ]),
            event("content_block_delta", [
                "index": .int(0),
                "delta": .object(["type": .string("signature_delta"), "signature": .string("sig")]),
            ]),
            event("content_block_delta", [
                "index": .int(0),
                "delta": .object(["type": .string("thinking_delta"), "thinking": .string("more")]),
            ]),
            event("content_block_stop", ["index": .int(0)]),
            event("message_delta", [
                "delta": .object(["stop_reason": .string("end_turn")]),
                "usage": .object(["output_tokens": .int(2)]),
            ]),
            event("message_stop"),
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.thinking == "think more")
        let done = try #require(recorder.done)
        #expect(done.content == [
            .thinking(ThinkingContent(thinking: "think more", thinkingSignature: "sig")),
        ])
        #expect(done.stopReason == .stop)
    }

    @Test func accumulatesToolUseArgumentsAcrossChunks() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            messageStart(usage: ["input_tokens": .int(5), "output_tokens": .int(1)]),
            event("content_block_start", [
                "index": .int(0),
                "content_block": .object([
                    "type": .string("tool_use"),
                    "id": .string("toolu_1"),
                    "name": .string("get_weather"),
                    "input": .object([:]),
                ]),
            ]),
            event("content_block_delta", [
                "index": .int(0),
                "delta": .object(["type": .string("input_json_delta"), "partial_json": .string("{\"city\":")]),
            ]),
            event("content_block_delta", [
                "index": .int(0),
                "delta": .object(["type": .string("input_json_delta"), "partial_json": .string("\"Paris\"}")]),
            ]),
            event("content_block_stop", ["index": .int(0)]),
            event("message_delta", [
                "delta": .object(["stop_reason": .string("tool_use")]),
                "usage": .object(["output_tokens": .int(3)]),
            ]),
            event("message_stop"),
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.thrown == nil)
        #expect(recorder.toolCallDeltas.map(\.index) == [0, 0])
        #expect(recorder.toolCallDeltas.map(\.fragment) == ["{\"city\":", "\"Paris\"}"])
        let done = try #require(recorder.done)
        #expect(done.stopReason == .toolUse)
        #expect(done.content == [
            .toolCall(ToolCall(id: "toolu_1", name: "get_weather", arguments: ["city": .string("Paris")])),
        ])
    }

    @Test func maxTokensStopReasonMapsToLength() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            messageStart(usage: ["input_tokens": .int(1), "output_tokens": .int(1)]),
            event("content_block_start", [
                "index": .int(0),
                "content_block": .object(["type": .string("text"), "text": .string("")]),
            ]),
            event("content_block_delta", [
                "index": .int(0),
                "delta": .object(["type": .string("text_delta"), "text": .string("truncated")]),
            ]),
            event("content_block_stop", ["index": .int(0)]),
            event("message_delta", [
                "delta": .object(["stop_reason": .string("max_tokens")]),
                "usage": .object(["output_tokens": .int(8)]),
            ]),
            event("message_stop"),
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))
        let done = try #require(recorder.done)
        #expect(done.stopReason == .length)
    }

    @Test func errorEventSurfacesAsError() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            event("error", [
                "error": .object([
                    "type": .string("overloaded_error"),
                    "message": .string("overloaded"),
                ]),
            ]),
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.done == nil)
        let error = try #require(recorder.error as? AnthropicMessagesStreamError)
        #expect(error == .providerError("overloaded_error: overloaded"))
    }

    @Test func streamWithoutMessageStopIsAnError() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            messageStart(usage: ["input_tokens": .int(1), "output_tokens": .int(1)]),
            event("content_block_start", [
                "index": .int(0),
                "content_block": .object(["type": .string("text"), "text": .string("hi")]),
            ]),
            event("message_delta", [
                "delta": .object(["stop_reason": .string("end_turn")]),
                "usage": .object(["output_tokens": .int(1)]),
            ]),
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.done == nil)
        #expect(recorder.error as? AnthropicMessagesStreamError == .missingTerminalEvent)
    }

    // MARK: - Non-streaming

    @Test func parsesNonStreamingCompletion() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(#"""
        {"id":"msg_2","type":"message","role":"assistant","model":"claude-sonnet-4","content":[{"type":"thinking","thinking":"pondering","signature":"sig-1"},{"type":"text","text":"Hello there"}],"stop_reason":"end_turn","usage":{"input_tokens":12,"output_tokens":4,"cache_read_input_tokens":2,"cache_creation_input_tokens":1,"output_tokens_details":{"thinking_tokens":3}}}
        """#))
        let message = try await makeProvider().complete(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context([.user(UserMessage(content: "hi", timestamp: 0))]),
            options: ChatOptions(apiKey: "test")
        )

        #expect(message.api == "anthropic-messages")
        #expect(message.provider == "anthropic")
        #expect(message.model == "claude-sonnet-4")
        #expect(message.responseId == "msg_2")
        #expect(message.stopReason == .stop)
        #expect(message.content == [
            .thinking(ThinkingContent(thinking: "pondering", thinkingSignature: "sig-1")),
            .text(TextContent(text: "Hello there")),
        ])
        #expect(message.usage.input == 12)
        #expect(message.usage.output == 4)
        #expect(message.usage.cacheRead == 2)
        #expect(message.usage.cacheWrite == 1)
        #expect(message.usage.reasoning == 3)
        #expect(message.usage.totalTokens == 19)
    }

    @Test func parsesNonStreamingToolCall() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(#"""
        {"id":"msg_3","type":"message","role":"assistant","model":"claude-sonnet-4","content":[{"type":"tool_use","id":"toolu_9","name":"lookup","input":{"q":"swift"}}],"stop_reason":"tool_use","usage":{"input_tokens":3,"output_tokens":5}}
        """#))
        let message = try await makeProvider().complete(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        )

        #expect(message.stopReason == .toolUse)
        #expect(message.content == [
            .toolCall(ToolCall(id: "toolu_9", name: "lookup", arguments: ["q": .string("swift")])),
        ])
    }

    // MARK: - Errors and retry

    @Test func nonRetryableHTTPErrorThrows() async {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(#"{"type":"error","error":{"type":"invalid_request_error","message":"bad request"}}"#, statusCode: 400))
        let provider = makeProvider(maxRetries: 3)
        do {
            _ = try await provider.complete(
                model: makeModel(baseURL: endpoint.baseURL),
                context: context(),
                options: ChatOptions(apiKey: "test")
            )
            Issue.record("expected error")
        } catch let error as ProviderHTTPError {
            #expect(error.status == 400)
            #expect(endpoint.requestCount == 1)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func retries429ThenSucceeds() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(
            #"{"type":"error","error":{"type":"rate_limit_error","message":"rate limited"}}"#,
            statusCode: 429,
            headers: ["retry-after-ms": "1"]
        ))
        endpoint.enqueue(.json(
            #"{"id":"msg_4","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#
        ))
        let message = try await makeProvider(maxRetries: 1).complete(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        )
        #expect(message.content == [.text(TextContent(text: "ok"))])
        #expect(endpoint.requestCount == 2)
    }

    @Test func missingAPIKeyThrows() {
        #expect(throws: OpenAIRequestError.self) {
            _ = try AnthropicMessagesRequestBuilder.makeRequest(
                model: makeModel(),
                context: context(),
                options: ChatOptions()
            )
        }
    }
}
