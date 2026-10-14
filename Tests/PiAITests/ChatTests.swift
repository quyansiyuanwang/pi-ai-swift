import Foundation
import Testing
@testable import PiAI

private struct StubError: Error, Sendable {
    let message: String
}

/// A thread-safe counter so `@Sendable` cancellation handlers can be asserted.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct MockChatProvider: ChatProvider {
    func stream(
        model: Model,
        context: ChatContext,
        options: ChatOptions
    ) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.start)
            continuation.yield(.done(AssistantMessage(model: model.id)))
            continuation.finish()
        }
    }
}

@Suite struct ChatTests {
    @Test func cancellationSignalCancelAndHandlers() {
        let signal = CancellationSignal()
        #expect(!signal.isCancelled)

        let counter = Counter()
        signal.onCancel { counter.increment() }
        signal.onCancel { counter.increment() }

        signal.cancel()
        signal.cancel()

        #expect(signal.isCancelled)
        #expect(counter.count == 2)
    }

    @Test func onCancelRunsImmediatelyWhenAlreadyCancelled() {
        let signal = CancellationSignal()
        signal.cancel()

        let counter = Counter()
        signal.onCancel { counter.increment() }
        #expect(counter.count == 1)
    }

    @Test func chatContextRoundTrip() throws {
        let context = ChatContext(
            systemPrompt: "Be terse.",
            messages: [
                .user(UserMessage(content: "hello", timestamp: 1)),
                .assistant(
                    AssistantMessage(
                        content: [.text(TextContent(text: "hi"))],
                        model: "gpt-4o",
                        stopReason: .stop,
                        timestamp: 2
                    )
                ),
            ],
            tools: [
                Tool(
                    name: "echo",
                    description: "Echoes input",
                    parameters: .object(
                        properties: ["text": .string()],
                        required: ["text"],
                        additionalProperties: false
                    )
                )
            ]
        )
        #expect(try TestSupport.roundTrip(context) == context)
    }

    @Test func chatOptionsDefaults() {
        let options = ChatOptions()
        #expect(options.apiKey == "")
        #expect(options.temperature == nil)
        #expect(options.maxTokens == nil)
        #expect(options.headers.isEmpty)
        #expect(options.signal == nil)

        let signal = CancellationSignal()
        let configured = ChatOptions(
            apiKey: "sk-test",
            temperature: 0.5,
            maxTokens: 256,
            headers: ["X-Test": "1"],
            signal: signal
        )
        #expect(configured.apiKey == "sk-test")
        #expect(configured.temperature == 0.5)
        #expect(configured.maxTokens == 256)
        #expect(configured.headers == ["X-Test": "1"])
        #expect(configured.signal === signal)
    }

    @Test func assistantMessageEventPatterns() {
        func classify(_ event: AssistantMessageEvent) -> String {
            switch event {
            case .start:
                return "start"
            case .textDelta(let text):
                return "text:\(text)"
            case .thinkingDelta(let text):
                return "thinking:\(text)"
            case .toolCallDelta(let index, let id, let name, let fragment):
                return "tool:\(index):\(id ?? "-"):\(name ?? "-"):\(fragment)"
            case .done(let message):
                return "done:\(message.model)"
            case .error(let error):
                return "error:\((error as? StubError)?.message ?? "unknown")"
            }
        }

        #expect(classify(.start) == "start")
        #expect(classify(.textDelta("hi")) == "text:hi")
        #expect(classify(.thinkingDelta("why")) == "thinking:why")
        #expect(
            classify(.toolCallDelta(index: 0, id: "call_1", name: "lookup", argumentsFragment: "{\"a\":"))
                == "tool:0:call_1:lookup:{\"a\":"
        )
        #expect(classify(.done(AssistantMessage(model: "gpt-4o"))) == "done:gpt-4o")
        #expect(classify(.error(StubError(message: "boom"))) == "error:boom")
    }

    @Test func mockProviderStreamsEvents() async throws {
        let provider = MockChatProvider()
        let model = Model(
            id: "gpt-4o",
            name: "GPT-4o",
            api: "openai-completions",
            provider: "openai",
            baseURL: "https://example.com/v1",
            contextWindow: 128_000,
            maxTokens: 16_384
        )
        var events: [String] = []
        for try await event in provider.stream(
            model: model,
            context: ChatContext(),
            options: ChatOptions(apiKey: "sk-test")
        ) {
            switch event {
            case .start: events.append("start")
            case .done(let message): events.append("done:\(message.model)")
            default: events.append("other")
            }
        }
        #expect(events == ["start", "done:gpt-4o"])
    }
}
