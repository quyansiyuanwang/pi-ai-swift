import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PiAI

/// A deterministic, offline walkthrough of the PiAI request/streaming pipeline.
///
/// It demonstrates the complete "streaming + one tool call" chain without an
/// API key:
///
/// 1. the user asks a question with a `get_weather` tool declared;
/// 2. the provider streams an assistant message carrying a tool call;
/// 3. the example executes the tool locally;
/// 4. the assistant message and the tool result are sent back in a second
///    streamed request that produces the final answer.
///
/// All HTTP traffic is served by ``ExampleMockURLProtocol``; no network is used.
/// Run with `swift run PiAIExamples`.
@main
struct PiAIExample {
    enum ExampleError: Error {
        case emptyStream
        case missingToolCall
    }

    static func main() async throws {
        let model = Model(
            id: "gpt-4o-mini",
            name: "GPT-4o mini",
            api: "openai-completions",
            provider: "openai",
            baseURL: "https://api.example.com/v1",
            contextWindow: 128_000,
            maxTokens: 16_384,
            reasoning: false,
            input: [.text],
            cost: ModelCost(input: 0.15, output: 0.60, cacheRead: 0.075, cacheWrite: 0.30)
        )

        let weatherTool = Tool(
            name: "get_weather",
            description: "Get the current weather for a city.",
            parameters: JSONSchema(
                type: [.object],
                properties: [
                    "city": JSONSchema(type: [.string], description: "The city name."),
                ],
                required: ["city"],
                additionalProperties: .bool(false)
            )
        )

        ExampleMockURLProtocol.reset(responses: [Self.toolCallSSE, Self.finalAnswerSSE])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExampleMockURLProtocol.self]
        let provider = OpenAICompletionsProvider(
            httpClient: URLSessionHTTPClient(configuration: configuration)
        )

        var context = ChatContext(
            systemPrompt: "You are a concise weather assistant.",
            messages: [.user(UserMessage(content: "What is the weather in Paris?", timestamp: 0))],
            tools: [weatherTool]
        )

        print("== Turn 1: ask for the weather ==")
        let assistant = try await streamMessage(provider: provider, model: model, context: context)
        guard case .toolCall(let call) = assistant.content.first(where: { block in
            if case .toolCall = block { return true }
            return false
        }) else {
            throw ExampleError.missingToolCall
        }
        print("Tool call: \(call.name)(\(call.arguments))")

        // Execute the tool locally (deterministic stub implementation).
        let toolResult = ToolResultMessage(
            toolCallId: call.id,
            toolName: call.name,
            text: #"{"city":"Paris","temperatureF":72,"conditions":"sunny"}"#
        )

        context.messages.append(.assistant(assistant))
        context.messages.append(.toolResult(toolResult))

        print("\n== Turn 2: send the tool result back ==")
        let final = try await streamMessage(provider: provider, model: model, context: context)

        let billed = model.applyingCost(to: final.usage)
        let answer = final.content.compactMap { block -> String? in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined()
        print("\nFinal answer: \(answer)")
        print(String(
            format: "Usage: input=%d output=%d cacheRead=%d -> $%.8f",
            billed.input,
            billed.output,
            billed.cacheRead,
            billed.cost.total
        ))
    }

    /// Consumes a stream, printing every event, and returns the final message.
    static func streamMessage(
        provider: OpenAICompletionsProvider,
        model: Model,
        context: ChatContext
    ) async throws -> AssistantMessage {
        let stream = provider.stream(
            model: model,
            context: context,
            options: ChatOptions(apiKey: "example-key")
        )

        var final: AssistantMessage?
        for try await event in stream {
            switch event {
            case .start:
                print("  <- start")
            case .textDelta(let delta):
                print("  <- text: \(delta)")
            case .thinkingDelta(let delta):
                print("  <- thinking: \(delta)")
            case .toolCallDelta(let index, let id, let name, let fragment):
                print("  <- toolCall[\(index)] id=\(id ?? "-") name=\(name ?? "-") args+=\(fragment)")
            case .done(let message):
                final = message
                print("  <- done (\(message.stopReason.rawValue))")
            case .error(let error):
                throw error
            }
        }

        guard let final else { throw ExampleError.emptyStream }
        return final
    }

    // MARK: - Mock SSE bodies

    /// The first response: an assistant tool call split across chunks.
    static let toolCallSSE = """
    data: {"id":"chatcmpl-1","model":"gpt-4o-mini","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_weather","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}

    data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"city\\":"}}]}}]}

    data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"Paris\\"}"}}]}}]}

    data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}

    data: [DONE]

    """

    /// The second response: a streamed natural-language answer.
    static let finalAnswerSSE = """
    data: {"id":"chatcmpl-2","model":"gpt-4o-mini","choices":[{"index":0,"delta":{"content":"It is "}}]}

    data: {"choices":[{"index":0,"delta":{"content":"72°F "}}]}

    data: {"choices":[{"index":0,"delta":{"content":"and sunny in Paris."}}]}

    data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":20,"completion_tokens":8}}

    data: [DONE]

    """
}

/// A minimal `URLProtocol` that serves queued `text/event-stream` bodies.
///
/// The example only needs sequential, deterministic responses, so the queue is
/// guarded by a single lock and shared for the whole process.
final class ExampleMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String] = []
    nonisolated(unsafe) private static var index = 0

    static func reset(responses: [String]) {
        lock.lock()
        Self.responses = responses
        index = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        let body: String
        if Self.index < Self.responses.count {
            body = Self.responses[Self.index]
        } else {
            body = "data: [DONE]\n\n"
        }
        Self.index += 1
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        // Deliver the body as individual SSE lines to exercise incrementality.
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            client?.urlProtocol(self, didLoad: Data("\(line)\n".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
