import Foundation
import Testing
@testable import PiAI

@Suite struct OpenAICompletionsProviderTests {
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

    private func makeProvider(maxRetries: Int = 0, maxRetryDelayMs: Int? = nil) -> OpenAICompletionsProvider {
        OpenAICompletionsProvider(
            httpClient: URLSessionHTTPClient(configuration: MockURLProtocol.makeConfiguration()),
            maxRetries: maxRetries,
            maxRetryDelayMs: maxRetryDelayMs
        )
    }

    private func completionJSON(
        content: String = "hello",
        finishReason: String = "stop"
    ) -> String {
        #"""
        {"id":"chatcmpl-1","model":"gpt-4o-mini","choices":[{"index":0,"message":{"role":"assistant","content":"\#(content)"},"finish_reason":"\#(finishReason)"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":0},"completion_tokens_details":{"reasoning_tokens":0}}}
        """#
    }

    @Test func successfulCompletionReturnsAssistantMessage() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(completionJSON(content: "hello world")))
        let provider = makeProvider()
        let message = try await provider.complete(
            model: makeModel(baseURL: endpoint.baseURL),
            context: ChatContext(messages: [.user(UserMessage(content: "hi", timestamp: 0))]),
            options: ChatOptions(apiKey: "test")
        )
        #expect(message.content == [.text(TextContent(text: "hello world"))])
        #expect(message.stopReason == .stop)
        #expect(message.responseId == "chatcmpl-1")
        #expect(message.usage.totalTokens == 5)
        #expect(endpoint.requestCount == 1)
    }

    @Test func sendsExpectedRequest() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(completionJSON()))
        let provider = makeProvider()
        _ = try await provider.complete(
            model: makeModel(baseURL: endpoint.baseURL),
            context: ChatContext(
                systemPrompt: "be nice",
                messages: [.user(UserMessage(content: "hi", timestamp: 0))]
            ),
            options: ChatOptions(apiKey: "test", temperature: 0.2, maxTokens: 42)
        )

        let request = try #require(endpoint.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "\(endpoint.baseURL)/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request.httpBody)
        let value = try JSONDecoder().decode(JSONValue.self, from: body)
        #expect(value["model"] == .string("gpt-4o-mini"))
        #expect(value["stream"] == .bool(false))
        #expect(value["max_tokens"] == .int(42))
        #expect(value["temperature"] == .number(0.2))
        #expect(value["messages"][0]["content"] == .string("be nice"))
        #expect(value["messages"][1]["content"] == .string("hi"))
    }

    @Test func retries429ThenSucceedsWithExactlyTwoCalls() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(
            #"{"error":{"message":"rate limited"}}"#,
            statusCode: 429,
            headers: ["retry-after-ms": "1"]
        ))
        endpoint.enqueue(.json(completionJSON(content: "after retry")))
        let provider = makeProvider(maxRetries: 1)
        let message = try await provider.complete(
            model: makeModel(baseURL: endpoint.baseURL),
            context: ChatContext(messages: [.user(UserMessage(content: "hi", timestamp: 0))]),
            options: ChatOptions(apiKey: "test")
        )
        #expect(message.content == [.text(TextContent(text: "after retry"))])
        #expect(endpoint.requestCount == 2)
    }

    @Test func nonRetryableErrorThrowsProviderHTTPError() async {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(
            #"{"error":{"message":"bad request"}}"#,
            statusCode: 400
        ))
        let provider = makeProvider(maxRetries: 3)
        do {
            _ = try await provider.complete(
                model: makeModel(baseURL: endpoint.baseURL),
                context: ChatContext(messages: [.user(UserMessage(content: "hi", timestamp: 0))]),
                options: ChatOptions(apiKey: "test")
            )
            Issue.record("expected error")
        } catch let error as ProviderHTTPError {
            #expect(error.status == 400)
            #expect(error.message == "bad request")
            #expect(endpoint.requestCount == 1)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func errorBodyMessageIsSurfacedInRetryCapFailure() async {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(
            #"{"error":{"message":"rate limited hard"}}"#,
            statusCode: 429,
            headers: ["retry-after": "277403"]
        ))
        let provider = makeProvider(maxRetries: 1, maxRetryDelayMs: 1000)
        do {
            _ = try await provider.complete(
                model: makeModel(baseURL: endpoint.baseURL),
                context: ChatContext(messages: [.user(UserMessage(content: "hi", timestamp: 0))]),
                options: ChatOptions(apiKey: "test")
            )
            Issue.record("expected error")
        } catch let error as ProviderHTTPError {
            #expect(error.message.contains("Server requested 277403s retry delay (max: 1s)"))
            #expect(error.message.contains("rate limited hard"))
            #expect(endpoint.requestCount == 1)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func cancelledSignalThrowsCancellationError() async {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(completionJSON()))
        let signal = CancellationSignal()
        signal.cancel()
        let provider = makeProvider()
        do {
            _ = try await provider.complete(
                model: makeModel(baseURL: endpoint.baseURL),
                context: ChatContext(messages: [.user(UserMessage(content: "hi", timestamp: 0))]),
                options: ChatOptions(apiKey: "test", signal: signal)
            )
            Issue.record("expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }
}
