import Foundation
import Testing
@testable import PiAI

@Suite struct OpenAIStreamingTests {
    // MARK: - Helpers

    private func makeModel(baseURL: String) -> Model {
        Model(
            id: "gpt-4o-mini",
            name: "GPT-4o mini",
            api: "openai-completions",
            provider: "openai",
            baseURL: baseURL,
            contextWindow: 128_000,
            maxTokens: 16_384
        )
    }

    private func makeProvider(maxRetries: Int = 0) -> OpenAICompletionsProvider {
        OpenAICompletionsProvider(
            httpClient: URLSessionHTTPClient(configuration: MockURLProtocol.makeConfiguration()),
            maxRetries: maxRetries
        )
    }

    private func chunk(_ json: String) -> Data {
        Data("data: \(json)\n\n".utf8)
    }

    private var doneChunk: Data {
        Data("data: [DONE]\n\n".utf8)
    }

    private func context() -> ChatContext {
        ChatContext(messages: [.user(UserMessage(content: "hi", timestamp: 0))])
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

    // MARK: - Normal stream

    @Test func streamsTextDeltasAndFinishes() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            chunk(#"{"id":"chatcmpl-1","model":"gpt-4o-mini","choices":[{"index":0,"delta":{"role":"assistant","content":"Hel"}}]}"#),
            chunk(#"{"choices":[{"index":0,"delta":{"content":"lo"}}]}"#),
            chunk(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":0},"completion_tokens_details":{"reasoning_tokens":0}}}"#),
            doneChunk,
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.started)
        #expect(recorder.thrown == nil)
        #expect(recorder.error == nil)
        #expect(recorder.text == "Hello")
        let done = try #require(recorder.done)
        #expect(done.content == [.text(TextContent(text: "Hello"))])
        #expect(done.stopReason == .stop)
        #expect(done.responseId == "chatcmpl-1")
        #expect(done.usage.totalTokens == 5)
    }

    @Test func sendsStreamingRequestWithUsageOptions() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            chunk(#"{"choices":[{"delta":{"content":"hi"},"finish_reason":"stop"}]}"#),
            doneChunk,
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test", temperature: 0.3)
        ))
        #expect(recorder.done != nil)

        let request = try #require(endpoint.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        #expect(body["stream"] == .bool(true))
        #expect(body["stream_options"]["include_usage"] == .bool(true))
        #expect(body["temperature"] == .number(0.3))
    }

    // MARK: - Tool call fragments

    @Test func accumulatesToolCallFragmentsByIndex() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            chunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}"#),
            chunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]}}]}"#),
            chunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Paris\"}"}}]}}]}"#),
            chunk(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#),
            doneChunk,
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.thrown == nil)
        #expect(recorder.toolCallDeltas.map(\.index) == [0, 0, 0])
        #expect(recorder.toolCallDeltas.map(\.fragment) == ["", "{\"city\":", "\"Paris\"}"])
        let done = try #require(recorder.done)
        #expect(done.stopReason == .toolUse)
        guard case .toolCall(let call)? = done.content.first else {
            Issue.record("expected a tool call block")
            return
        }
        #expect(call.id == "call_1")
        #expect(call.name == "get_weather")
        #expect(call.arguments == .object(["city": .string("Paris")]))
    }

    @Test func interleavesMultipleToolCallsByIndex() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            chunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"beta","arguments":"{\"x\":"}},{"index":0,"id":"a","function":{"name":"alpha","arguments":"{}"}}]}}]}"#),
            chunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"1}"}}]}}]}"#),
            chunk(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#),
            doneChunk,
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        let done = try #require(recorder.done)
        guard case .toolCall(let first)? = done.content.first,
              case .toolCall(let second)? = done.content.last else {
            Issue.record("expected two tool calls")
            return
        }
        #expect(first.id == "b")
        #expect(first.name == "beta")
        #expect(first.arguments == .object(["x": .int(1)]))
        #expect(second.id == "a")
        #expect(second.name == "alpha")
    }

    // MARK: - [DONE]

    @Test func doneSentinelEndsStreamWithoutFinishReason() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            chunk(#"{"choices":[{"delta":{"content":"hi"}}]}"#),
            doneChunk,
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.text == "hi")
        #expect(recorder.error == nil)
        #expect(recorder.thrown == nil)
        #expect(recorder.done?.stopReason == .stop)
        #expect(recorder.done?.content == [.text(TextContent(text: "hi"))])
    }

    @Test func missingFinishReasonWithoutDoneIsAnError() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            chunk(#"{"choices":[{"delta":{"content":"partial"}}]}"#),
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.done == nil)
        #expect(recorder.error as? OpenAIStreamError == .missingFinishReason)
    }

    // MARK: - Reasoning

    @Test func reasoningContentBecomesThinkingDeltas() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            chunk(#"{"choices":[{"delta":{"reasoning_content":"think "}}]}"#),
            chunk(#"{"choices":[{"delta":{"reasoning_content":"more"}}]}"#),
            chunk(#"{"choices":[{"delta":{"content":"answer"}}]}"#),
            chunk(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#),
            doneChunk,
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.thinking == "think more")
        #expect(recorder.text == "answer")
        let done = try #require(recorder.done)
        #expect(done.content == [
            .thinking(ThinkingContent(thinking: "think more", thinkingSignature: "reasoning_content")),
            .text(TextContent(text: "answer")),
        ])
    }

    // MARK: - UTF-8 across chunk boundaries

    @Test func reassemblesMultibyteTextSplitAcrossChunks() async throws {
        let endpoint = MockEndpoint()
        let payload = #"{"choices":[{"index":0,"delta":{"content":"你好🌍"}}]}"#
        // One byte per chunk exercises every possible character split.
        let chunks = Data("data: \(payload)\n\n".utf8).map { Data([$0]) }
        endpoint.enqueue(.stream(chunks + [doneChunk], delayMs: 0))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.text == "你好🌍")
        #expect(recorder.done != nil)
    }

    // MARK: - Mid-stream disconnect

    @Test func networkFailureMidStreamEmitsErrorEvent() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            chunk(#"{"choices":[{"delta":{"content":"partial"}}]}"#),
        ], delayMs: 1, error: URLError(.networkConnectionLost)))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.done == nil)
        #expect(recorder.thrown == nil)
        #expect(recorder.error != nil)
    }

    // MARK: - HTTP errors and retry

    @Test func nonRetryableHTTPErrorIsDeliveredAsErrorEvent() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(#"{"error":{"message":"bad request"}}"#, statusCode: 400))
        let recorder = await run(makeProvider(maxRetries: 3).stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.done == nil)
        let error = try #require(recorder.error as? ProviderHTTPError)
        #expect(error.status == 400)
        #expect(error.message == "bad request")
        #expect(endpoint.requestCount == 1)
    }

    @Test func retries429ThenStreams() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(
            #"{"error":{"message":"rate limited"}}"#,
            statusCode: 429,
            headers: ["retry-after-ms": "1"]
        ))
        endpoint.enqueue(.stream([
            chunk(#"{"choices":[{"delta":{"content":"after retry"},"finish_reason":"stop"}]}"#),
            doneChunk,
        ]))
        let recorder = await run(makeProvider(maxRetries: 1).stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.text == "after retry")
        #expect(recorder.done != nil)
        #expect(endpoint.requestCount == 2)
    }

    // MARK: - Cancellation

    @Test func cancellingSignalThrowsCancellationError() async throws {
        let endpoint = MockEndpoint()
        let slowChunks = (0..<200).map { _ in
            chunk(#"{"choices":[{"delta":{"content":"x"}}]}"#)
        }
        endpoint.enqueue(.stream(slowChunks, delayMs: 5))

        let signal = CancellationSignal()
        let stream = makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test", signal: signal)
        )

        var thrown: (any Error)?
        var deltas = 0
        do {
            for try await event in stream {
                if case .textDelta = event {
                    deltas += 1
                    if deltas == 2 { signal.cancel() }
                }
            }
        } catch {
            thrown = error
        }
        #expect(thrown is CancellationError)
    }

    @Test func cancellingConsumingTaskThrowsCancellationError() async throws {
        let endpoint = MockEndpoint()
        let slowChunks = (0..<200).map { _ in
            chunk(#"{"choices":[{"delta":{"content":"x"}}]}"#)
        }
        endpoint.enqueue(.stream(slowChunks, delayMs: 5))

        let stream = makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test")
        )
        let task = Task { () -> (any Error)? in
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        task.cancel()
        let thrown = await task.value
        #expect(thrown is CancellationError)
    }

    @Test func cancellationIsNotRetried() async throws {
        let endpoint = MockEndpoint()
        let slowChunks = (0..<200).map { _ in
            chunk(#"{"choices":[{"delta":{"content":"x"}}]}"#)
        }
        endpoint.enqueue(.stream(slowChunks, delayMs: 5))

        let signal = CancellationSignal()
        let provider = makeProvider(maxRetries: 5)
        let stream = provider.stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: context(),
            options: ChatOptions(apiKey: "test", signal: signal)
        )

        var thrown: (any Error)?
        var deltas = 0
        do {
            for try await event in stream {
                if case .textDelta = event {
                    deltas += 1
                    if deltas == 1 { signal.cancel() }
                }
            }
        } catch {
            thrown = error
        }
        #expect(thrown is CancellationError)
        #expect(endpoint.requestCount == 1)
    }
}
