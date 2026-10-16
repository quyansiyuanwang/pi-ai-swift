import Foundation
import Testing
@testable import PiAI

@Suite struct OpenAIResponsesTests {
    // MARK: - Helpers

    private func makeModel(
        id: String = "gpt-5",
        provider: String = "openai",
        baseURL: String = "https://api.openai.com/v1",
        api: String = "openai-responses",
        reasoning: Bool = true,
        input: [ModelInputModality] = [.text, .image]
    ) -> Model {
        Model(
            id: id,
            name: id,
            api: api,
            provider: provider,
            baseURL: baseURL,
            contextWindow: 128_000,
            maxTokens: 16_384,
            reasoning: reasoning,
            input: input
        )
    }

    private func makeProvider(
        maxRetries: Int = 0,
        reasoningEffort: String? = nil
    ) -> OpenAIResponsesProvider {
        OpenAIResponsesProvider(
            httpClient: URLSessionHTTPClient(configuration: MockURLProtocol.makeConfiguration()),
            maxRetries: maxRetries,
            reasoningEffort: reasoningEffort
        )
    }

    /// Serializes an event object as an SSE `data:` frame. Building payloads
    /// from `JSONObject` values avoids fragile escape sequences in test JSON.
    private func sse(_ object: JSONObject) -> Data {
        let data = (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data()
        return Data("data: \(String(decoding: data, as: UTF8.self))\n\n".utf8)
    }

    private func event(_ type: String, _ extra: JSONObject = [:]) -> Data {
        var object = extra
        object["type"] = .string(type)
        return sse(object)
    }

    private var completedEvent: Data {
        event("response.completed", [
            "response": .object([
                "id": .string("resp_1"),
                "status": .string("completed"),
                "usage": .object([
                    "input_tokens": .int(10),
                    "output_tokens": .int(2),
                    "total_tokens": .int(12),
                    "input_tokens_details": .object(["cached_tokens": .int(3)]),
                    "output_tokens_details": .object(["reasoning_tokens": .int(1)]),
                ]),
                "output": .array([]),
            ]),
        ])
    }

    private func messageAdded(outputIndex: Int, id: String) -> Data {
        event("response.output_item.added", [
            "output_index": .int(outputIndex),
            "item": .object(["type": .string("message"), "id": .string(id)]),
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
        endpoint.enqueue(.json(#"{"id":"resp_1","status":"completed","output":[]}"#))
        let provider = makeProvider(reasoningEffort: "high")
        _ = try await provider.complete(
            model: makeModel(baseURL: endpoint.baseURL),
            context: ChatContext(
                systemPrompt: "be helpful",
                messages: [.user(UserMessage(content: "hi", timestamp: 0))]
            ),
            options: ChatOptions(apiKey: "test", temperature: 0.4, maxTokens: 8, topP: 0.9)
        )

        let request = try #require(endpoint.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "\(endpoint.baseURL)/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        #expect(body["model"] == .string("gpt-5"))
        #expect(body["stream"] == .bool(false))
        #expect(body["store"] == .bool(false))
        #expect(body["max_output_tokens"] == .int(16))
        #expect(body["temperature"] == .number(0.4))
        #expect(body["top_p"] == .number(0.9))
        #expect(body["reasoning"]["effort"] == .string("high"))
        #expect(body["input"][0]["role"] == .string("developer"))
        #expect(body["input"][0]["content"] == .string("be helpful"))
        #expect(body["input"][1]["role"] == .string("user"))
        #expect(body["input"][1]["content"][0]["type"] == .string("input_text"))
    }

    @Test func maxOutputTokensAboveMinimumIsPreserved() {
        let body = OpenAIResponsesRequestBuilder.makeBody(
            model: makeModel(),
            context: context(),
            options: ChatOptions(maxTokens: 4096)
        )
        #expect(body["max_output_tokens"] == .int(4096))
    }

    @Test func streamingRequestSetsStreamTrue() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([completedEvent]))
        _ = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))
        let request = try #require(endpoint.lastRequest)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        #expect(body["stream"] == .bool(true))
    }

    @Test func reasoningOmittedWhenNotConfigured() {
        let body = OpenAIResponsesRequestBuilder.makeBody(
            model: makeModel(),
            context: context(),
            options: ChatOptions()
        )
        #expect(body["reasoning"].isNull)
    }

    // MARK: - Tool conversion

    @Test func toolConversionShape() {
        let tool = Tool(
            name: "lookup",
            description: "Look something up",
            parameters: .object(properties: ["q": .string()], required: ["q"])
        )
        let body = OpenAIResponsesRequestBuilder.makeBody(
            model: makeModel(),
            context: ChatContext(tools: [tool]),
            options: ChatOptions()
        )
        let serialized = body["tools"][0]
        #expect(serialized["type"] == .string("function"))
        #expect(serialized["name"] == .string("lookup"))
        #expect(serialized["description"] == .string("Look something up"))
        #expect(serialized["strict"] == .bool(false))
        #expect(serialized["parameters"]["type"] == .string("object"))
        #expect(serialized["parameters"]["properties"]["q"]["type"] == .string("string"))
        #expect(serialized["parameters"]["required"] == .array([.string("q")]))
    }

    @Test func emptyToolsOmitted() {
        let body = OpenAIResponsesRequestBuilder.makeBody(
            model: makeModel(),
            context: context(),
            options: ChatOptions()
        )
        #expect(body["tools"].isNull)
    }

    // MARK: - Message conversion

    @Test func systemPromptBecomesDeveloperInstructionForReasoningModels() {
        let body = OpenAIResponsesRequestBuilder.makeBody(
            model: makeModel(reasoning: true),
            context: ChatContext(systemPrompt: "be nice", messages: []),
            options: ChatOptions()
        )
        #expect(body["input"][0]["role"] == .string("developer"))
        #expect(body["input"][0]["content"] == .string("be nice"))
    }

    @Test func systemPromptBecomesSystemInstructionForNonReasoningModels() {
        let body = OpenAIResponsesRequestBuilder.makeBody(
            model: makeModel(reasoning: false),
            context: ChatContext(systemPrompt: "be nice", messages: []),
            options: ChatOptions()
        )
        #expect(body["input"][0]["role"] == .string("system"))
    }

    @Test func userMessageAndImageConversion() {
        let body = OpenAIResponsesRequestBuilder.makeBody(
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
        let content = body["input"][0]["content"]
        #expect(body["input"][0]["role"] == .string("user"))
        #expect(content[0]["type"] == .string("input_text"))
        #expect(content[0]["text"] == .string("describe"))
        #expect(content[1]["type"] == .string("input_image"))
        #expect(content[1]["image_url"] == .string("data:image/png;base64,aGk="))
    }

    @Test func assistantTextAndToolCallConversion() throws {
        let body = OpenAIResponsesRequestBuilder.makeBody(
            model: makeModel(),
            context: context([
                .assistant(AssistantMessage(
                    content: [.text(TextContent(text: "answer"))],
                    stopReason: .stop,
                    timestamp: 0
                )),
                .assistant(AssistantMessage(
                    content: [.toolCall(ToolCall(id: "call_1", name: "lookup", arguments: ["q": "swift"]))],
                    stopReason: .toolUse,
                    timestamp: 1
                )),
            ]),
            options: ChatOptions()
        )

        let message = body["input"][0]
        #expect(message["type"] == .string("message"))
        #expect(message["role"] == .string("assistant"))
        #expect(message["content"][0]["type"] == .string("output_text"))
        #expect(message["content"][0]["text"] == .string("answer"))

        let call = body["input"][1]
        #expect(call["type"] == .string("function_call"))
        #expect(call["call_id"] == .string("call_1"))
        #expect(call["name"] == .string("lookup"))
        let arguments = try #require(call["arguments"].stringValue)
        #expect(JSONParse.parse(arguments) == .object(["q": .string("swift")]))
    }

    @Test func toolResultConversion() {
        let body = OpenAIResponsesRequestBuilder.makeBody(
            model: makeModel(),
            context: context([
                .toolResult(ToolResultMessage(toolCallId: "call_1", toolName: "lookup", text: "Paris", timestamp: 0)),
            ]),
            options: ChatOptions()
        )
        let result = body["input"][0]
        #expect(result["type"] == .string("function_call_output"))
        #expect(result["call_id"] == .string("call_1"))
        #expect(result["output"] == .string("Paris"))
    }

    @Test func emptyToolResultUsesPlaceholder() {
        let body = OpenAIResponsesRequestBuilder.makeBody(
            model: makeModel(),
            context: context([
                .toolResult(ToolResultMessage(toolCallId: "call_1", toolName: "lookup", content: [], timestamp: 0)),
            ]),
            options: ChatOptions()
        )
        #expect(body["input"][0]["output"] == .string("(no tool output)"))
    }

    // MARK: - Streaming

    @Test func streamsTextDeltasAndUsage() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            event("response.created", ["response": .object(["id": .string("resp_1")])]),
            messageAdded(outputIndex: 0, id: "msg_1"),
            event("response.output_text.delta", ["output_index": .int(0), "delta": .string("Hel")]),
            event("response.output_text.delta", ["output_index": .int(0), "delta": .string("lo")]),
            event("response.output_item.done", [
                "output_index": .int(0),
                "item": .object([
                    "type": .string("message"),
                    "id": .string("msg_1"),
                    "content": .array([
                        .object(["type": .string("output_text"), "text": .string("Hello")]),
                    ]),
                ]),
            ]),
            completedEvent,
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
        #expect(done.api == "openai-responses")
        #expect(done.provider == "openai")
        #expect(done.model == "gpt-5")
        #expect(done.responseId == "resp_1")
        #expect(done.usage.input == 7)
        #expect(done.usage.output == 2)
        #expect(done.usage.cacheRead == 3)
        #expect(done.usage.reasoning == 1)
        #expect(done.usage.totalTokens == 12)
    }

    @Test func streamsThinkingDeltas() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            event("response.output_item.added", [
                "output_index": .int(0),
                "item": .object(["type": .string("reasoning"), "id": .string("rs_1")]),
            ]),
            event("response.reasoning_summary_text.delta", [
                "output_index": .int(0),
                "delta": .string("think "),
            ]),
            event("response.reasoning_text.delta", [
                "output_index": .int(0),
                "delta": .string("more"),
            ]),
            event("response.output_item.done", [
                "output_index": .int(0),
                "item": .object(["type": .string("reasoning"), "id": .string("rs_1")]),
            ]),
            completedEvent,
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.thinking == "think more")
        let done = try #require(recorder.done)
        #expect(done.content == [.thinking(ThinkingContent(thinking: "think more"))])
        #expect(done.stopReason == .stop)
    }

    @Test func accumulatesFunctionCallArgumentsAcrossDeltas() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            event("response.output_item.added", [
                "output_index": .int(0),
                "item": .object([
                    "type": .string("function_call"),
                    "id": .string("fc_1"),
                    "call_id": .string("call_1"),
                    "name": .string("get_weather"),
                    "arguments": .string(""),
                ]),
            ]),
            event("response.function_call_arguments.delta", [
                "output_index": .int(0),
                "delta": .string("{\"city\":"),
            ]),
            event("response.function_call_arguments.delta", [
                "output_index": .int(0),
                "delta": .string("\"Paris\"}"),
            ]),
            event("response.output_item.done", [
                "output_index": .int(0),
                "item": .object([
                    "type": .string("function_call"),
                    "id": .string("fc_1"),
                    "call_id": .string("call_1"),
                    "name": .string("get_weather"),
                    "arguments": .string("{\"city\":\"Paris\"}"),
                ]),
            ]),
            completedEvent,
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
            .toolCall(ToolCall(id: "call_1", name: "get_weather", arguments: ["city": .string("Paris")])),
        ])
    }

    @Test func functionCallArgumentsDoneEmitsRemainder() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            event("response.output_item.added", [
                "output_index": .int(0),
                "item": .object([
                    "type": .string("function_call"),
                    "id": .string("fc_1"),
                    "call_id": .string("call_1"),
                    "name": .string("f"),
                    "arguments": .string(""),
                ]),
            ]),
            event("response.function_call_arguments.delta", [
                "output_index": .int(0),
                "delta": .string("{\"a\":"),
            ]),
            event("response.function_call_arguments.done", [
                "output_index": .int(0),
                "arguments": .string("{\"a\":1}"),
            ]),
            event("response.output_item.done", [
                "output_index": .int(0),
                "item": .object([
                    "type": .string("function_call"),
                    "id": .string("fc_1"),
                    "call_id": .string("call_1"),
                    "name": .string("f"),
                    "arguments": .string("{\"a\":1}"),
                ]),
            ]),
            completedEvent,
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.toolCallDeltas.map(\.fragment) == ["{\"a\":", "1}"])
        let done = try #require(recorder.done)
        #expect(done.content == [.toolCall(ToolCall(id: "call_1", name: "f", arguments: ["a": .int(1)]))])
    }

    @Test func responseFailedEventSurfacesAsError() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            event("response.created", ["response": .object(["id": .string("resp_1")])]),
            event("response.failed", [
                "response": .object([
                    "status": .string("failed"),
                    "error": .object([
                        "code": .string("server_error"),
                        "message": .string("boom"),
                    ]),
                ]),
            ]),
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.done == nil)
        let error = try #require(recorder.error as? OpenAIResponsesStreamError)
        #expect(error == .providerError("server_error: boom"))
    }

    @Test func errorEventSurfacesAsError() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            event("error", [
                "code": .string("invalid_request"),
                "message": .string("bad input"),
            ]),
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.done == nil)
        let error = try #require(recorder.error as? OpenAIResponsesStreamError)
        #expect(error == .providerError("Error Code invalid_request: bad input"))
    }

    @Test func streamWithoutTerminalEventIsAnError() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            messageAdded(outputIndex: 0, id: "msg_1"),
            event("response.output_text.delta", ["output_index": .int(0), "delta": .string("hi")]),
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.done == nil)
        #expect(recorder.error as? OpenAIResponsesStreamError == .missingTerminalEvent)
    }

    // MARK: - Non-streaming

    @Test func parsesNonStreamingCompletion() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(#"""
        {"id":"resp_2","model":"gpt-5","status":"completed","output":[{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"thinking"}]},{"type":"message","id":"msg_2","content":[{"type":"output_text","text":"Hello there"}]}],"usage":{"input_tokens":12,"output_tokens":4,"total_tokens":16,"input_tokens_details":{"cached_tokens":2}}}
        """#))
        let message = try await makeProvider().complete(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context([.user(UserMessage(content: "hi", timestamp: 0))]),
            options: ChatOptions(apiKey: "test")
        )

        #expect(message.api == "openai-responses")
        #expect(message.provider == "openai")
        #expect(message.model == "gpt-5")
        #expect(message.responseId == "resp_2")
        #expect(message.stopReason == .stop)
        #expect(message.content == [
            .thinking(ThinkingContent(thinking: "thinking")),
            .text(TextContent(text: "Hello there")),
        ])
        #expect(message.usage.input == 10)
        #expect(message.usage.output == 4)
        #expect(message.usage.cacheRead == 2)
        #expect(message.usage.totalTokens == 16)
    }

    @Test func parsesNonStreamingToolCall() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(#"""
        {"id":"resp_3","status":"completed","output":[{"type":"function_call","id":"fc_9","call_id":"call_9","name":"lookup","arguments":"{\"q\":\"swift\"}"}]}
        """#))
        let message = try await makeProvider().complete(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        )

        #expect(message.stopReason == .toolUse)
        #expect(message.content == [
            .toolCall(ToolCall(id: "call_9", name: "lookup", arguments: ["q": .string("swift")])),
        ])
    }

    @Test func nonStreamingIncompleteMapsToLength() throws {
        let data = Data(
            #"{"id":"resp_4","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#.utf8
        )
        let message = try OpenAIResponsesResponseParser.parse(data, model: makeModel())
        #expect(message.stopReason == .length)
        #expect(message.rawStopReason == "incomplete.max_output_tokens")
    }

    // MARK: - Errors and retry

    @Test func nonRetryableHTTPErrorThrows() async {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(#"{"error":{"message":"bad request"}}"#, statusCode: 400))
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
            #"{"error":{"message":"rate limited"}}"#,
            statusCode: 429,
            headers: ["retry-after-ms": "1"]
        ))
        endpoint.enqueue(.json(
            #"{"id":"resp_5","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]}"#
        ))
        let message = try await makeProvider(maxRetries: 1).complete(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        )
        #expect(message.content == [.text(TextContent(text: "ok"))])
        #expect(endpoint.requestCount == 2)
    }
}
