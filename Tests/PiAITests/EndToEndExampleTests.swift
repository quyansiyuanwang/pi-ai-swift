import Foundation
import Testing
@testable import PiAI

/// Deterministic, offline end-to-end example: a streamed tool call followed by
/// a streamed final answer, with no real API key or network access.
///
/// This mirrors `Examples/PiAIExamples` inside the test target so the complete
/// chain is covered by `swift test`.
@Suite struct EndToEndExampleTests {
    // MARK: - Fixtures

    private func makeModel(baseURL: String) -> Model {
        Model(
            id: "gpt-4o-mini",
            name: "GPT-4o mini",
            api: "openai-completions",
            provider: "openai",
            baseURL: baseURL,
            contextWindow: 128_000,
            maxTokens: 16_384,
            input: [.text],
            cost: ModelCost(input: 0.15, output: 0.60, cacheRead: 0.075, cacheWrite: 0.30)
        )
    }

    private var weatherTool: Tool {
        Tool(
            name: "get_weather",
            description: "Get the current weather for a city.",
            parameters: JSONSchema(
                type: [.object],
                properties: ["city": JSONSchema(type: [.string], description: "The city name.")],
                required: ["city"],
                additionalProperties: .bool(false)
            )
        )
    }

    private func provider() -> OpenAICompletionsProvider {
        OpenAICompletionsProvider(
            httpClient: URLSessionHTTPClient(configuration: MockURLProtocol.makeConfiguration())
        )
    }

    private func chunk(_ json: String) -> Data {
        Data("data: \(json)\n\n".utf8)
    }

    private var doneChunk: Data {
        Data("data: [DONE]\n\n".utf8)
    }

    private func collect(
        _ stream: AsyncThrowingStream<AssistantMessageEvent, any Error>
    ) async throws -> (events: [AssistantMessageEvent], message: AssistantMessage?) {
        var events: [AssistantMessageEvent] = []
        var message: AssistantMessage?
        for try await event in stream {
            events.append(event)
            if case .done(let done) = event { message = done }
        }
        return (events, message)
    }

    // MARK: - Test

    @Test func streamingToolCallThenFinalAnswer() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            chunk(#"{"id":"chatcmpl-1","model":"gpt-4o-mini","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_weather","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}"#),
            chunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]}}]}"#),
            chunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Paris\"}"}}]}}]}"#),
            chunk(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#),
            doneChunk,
        ]))
        endpoint.enqueue(.stream([
            chunk(#"{"id":"chatcmpl-2","model":"gpt-4o-mini","choices":[{"index":0,"delta":{"content":"It is "}}]}"#),
            chunk(#"{"choices":[{"index":0,"delta":{"content":"72°F and sunny in Paris."}}]}"#),
            chunk(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":20,"completion_tokens":8}}"#),
            doneChunk,
        ]))

        let model = makeModel(baseURL: endpoint.baseURL)
        let tool = weatherTool

        // Turn 1: the model streams a tool call.
        let first = try await collect(provider().stream(
            model: model,
            context: ChatContext(
                systemPrompt: "You are a concise weather assistant.",
                messages: [.user(UserMessage(content: "What is the weather in Paris?", timestamp: 0))],
                tools: [tool]
            ),
            options: ChatOptions(apiKey: "test")
        ))

        let assistant = try #require(first.message)
        #expect(assistant.stopReason == .toolUse)
        #expect(first.events.contains { event in
            if case .toolCallDelta = event { return true }
            return false
        })
        guard case .toolCall(let call)? = assistant.content.first(where: { block in
            if case .toolCall = block { return true }
            return false
        }) else {
            Issue.record("expected a tool call")
            return
        }
        #expect(call.id == "call_weather")
        #expect(call.name == "get_weather")
        #expect(call.arguments == .object(["city": .string("Paris")]))

        // Execute the tool and append the result.
        let toolResult = ToolResultMessage(
            toolCallId: call.id,
            toolName: call.name,
            text: #"{"city":"Paris","temperatureF":72,"conditions":"sunny"}"#
        )
        let context = ChatContext(
            systemPrompt: "You are a concise weather assistant.",
            messages: [
                .user(UserMessage(content: "What is the weather in Paris?", timestamp: 0)),
                .assistant(assistant),
                .toolResult(toolResult),
            ],
            tools: [tool]
        )

        // Turn 2: the model streams the final answer.
        let second = try await collect(provider().stream(
            model: model,
            context: context,
            options: ChatOptions(apiKey: "test")
        ))
        let final = try #require(second.message)
        #expect(final.stopReason == .stop)
        #expect(final.content == [.text(TextContent(text: "It is 72°F and sunny in Paris."))])
        let answer = final.content.compactMap { block -> String? in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined()
        #expect(answer == "It is 72°F and sunny in Paris.")

        // Usage and cost are populated.
        let billed = model.applyingCost(to: final.usage)
        #expect(billed.input == 20)
        #expect(billed.output == 8)
        #expect(billed.cost.total > 0)

        // Both requests targeted the same chat-completions endpoint.
        #expect(endpoint.requestCount == 2)
        let secondBody = try JSONDecoder().decode(JSONValue.self, from: try #require(endpoint.lastRequest?.httpBody))
        #expect(secondBody["stream"] == JSONValue.bool(true))
        guard let messages = secondBody["messages"].arrayValue else {
            Issue.record("expected a messages array")
            return
        }
        #expect(messages.contains { message in
            message["role"] == JSONValue.string("tool")
                && message["tool_call_id"] == JSONValue.string("call_weather")
        })
        #expect(messages.contains { message in
            message["role"] == JSONValue.string("assistant") && message["tool_calls"] != JSONValue.null
        })
    }
}
