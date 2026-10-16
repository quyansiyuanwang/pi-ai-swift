import Foundation
import Testing
@testable import PiAI

@Suite struct GoogleGenerativeAITests {
    // MARK: - Helpers

    private func makeModel(
        id: String = "gemini-2.5-flash",
        provider: String = "google",
        baseURL: String,
        api: String = "google-generative-ai",
        maxTokens: Int = 8192
    ) -> Model {
        Model(
            id: id,
            name: id,
            api: api,
            provider: provider,
            baseURL: baseURL,
            contextWindow: 1_000_000,
            maxTokens: maxTokens,
            reasoning: true,
            input: [.text, .image]
        )
    }

    private func makeProvider(
        maxRetries: Int = 0,
        thinkingBudget: Int? = nil
    ) -> GoogleGenerativeAIProvider {
        GoogleGenerativeAIProvider(
            httpClient: URLSessionHTTPClient(configuration: MockURLProtocol.makeConfiguration()),
            maxRetries: maxRetries,
            thinkingBudget: thinkingBudget
        )
    }

    /// Serializes an object as an SSE `data:` frame.
    private func sse(_ object: JSONObject) -> Data {
        let data = (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data()
        return Data("data: \(String(decoding: data, as: UTF8.self))\n\n".utf8)
    }

    private func candidateChunk(
        parts: [JSONObject],
        finishReason: String? = nil
    ) -> JSONObject {
        var candidate: JSONObject = [
            "content": .object(["parts": .array(parts.map { .object($0) })]),
        ]
        if let finishReason { candidate["finishReason"] = .string(finishReason) }
        return ["candidates": .array([.object(candidate)])]
    }

    private func requestBody(_ request: URLRequest?) throws -> JSONValue {
        let request = try #require(request)
        return try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
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

    // MARK: - URL resolution

    @Test func resolvesURLWithoutDuplicatingVersionSegment() throws {
        func resolve(_ base: String, streaming: Bool) throws -> String {
            try GoogleGenerativeAIRequestBuilder
                .resolveURL(baseURL: base, model: "gemini-2.5-flash", streaming: streaming)
                .absoluteString
        }

        #expect(
            try resolve("https://api.google.com", streaming: false)
                == "https://api.google.com/v1beta/models/gemini-2.5-flash:generateContent"
        )
        #expect(
            try resolve("https://api.google.com/", streaming: true)
                == "https://api.google.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
        )
        #expect(
            try resolve("https://api.google.com/v1beta", streaming: true)
                == "https://api.google.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
        )
        #expect(
            try resolve("https://api.google.com/v1beta/", streaming: false)
                == "https://api.google.com/v1beta/models/gemini-2.5-flash:generateContent"
        )
        #expect(
            try resolve("https://api.google.com/v1", streaming: false)
                == "https://api.google.com/v1/models/gemini-2.5-flash:generateContent"
        )
    }

    @Test func invalidBaseURLThrows() {
        #expect(throws: GoogleGenerativeAIRequestError.self) {
            _ = try GoogleGenerativeAIRequestBuilder.resolveURL(
                baseURL: "not a url",
                model: "gemini-2.5-flash",
                streaming: false
            )
        }
    }

    // MARK: - Request building

    @Test func sendsStreamingRequest() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            sse(candidateChunk(parts: [["text": .string("hi")]], finishReason: "STOP")),
        ]))
        let recorder = await run(makeProvider(thinkingBudget: 1024).stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: ChatContext(
                systemPrompt: "be nice",
                messages: [.user(UserMessage(content: "hello", timestamp: 0))],
                tools: [
                    Tool(
                        name: "lookup",
                        description: "Look something up",
                        parameters: .object(properties: ["q": .string()], required: ["q"])
                    ),
                ]
            ),
            options: ChatOptions(apiKey: "test", temperature: 0.2, maxTokens: 256, topP: 0.8)
        ))

        #expect(recorder.thrown == nil)
        #expect(recorder.text == "hi")

        let request = try #require(endpoint.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(
            request.url?.absoluteString
                == "\(endpoint.baseURL)/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
        )
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try requestBody(request)
        #expect(body["contents"][0]["role"] == .string("user"))
        #expect(body["contents"][0]["parts"][0]["text"] == .string("hello"))
        #expect(body["systemInstruction"]["parts"][0]["text"] == .string("be nice"))
        #expect(body["tools"][0]["functionDeclarations"][0]["name"] == .string("lookup"))
        #expect(body["generationConfig"]["temperature"] == .number(0.2))
        #expect(body["generationConfig"]["topP"] == .number(0.8))
        #expect(body["generationConfig"]["maxOutputTokens"] == .int(256))
        #expect(body["generationConfig"]["thinkingConfig"]["thinkingBudget"] == .int(1024))
    }

    @Test func sendsNonStreamingRequest() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(#"""
        {"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1,"totalTokenCount":2}}
        """#))
        _ = try await makeProvider().complete(
            model: makeModel(baseURL: endpoint.baseURL),
            context: ChatContext(messages: [.user(UserMessage(content: "hi", timestamp: 0))]),
            options: ChatOptions(apiKey: "test")
        )

        let request = try #require(endpoint.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(
            request.url?.absoluteString
                == "\(endpoint.baseURL)/models/gemini-2.5-flash:generateContent"
        )
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test")

        let body = try requestBody(request)
        #expect(body["contents"][0]["parts"][0]["text"] == .string("hi"))
        // No sampling options and no thinking budget => generationConfig omitted.
        #expect(body["generationConfig"].isNull)
        #expect(body["tools"].isNull)
    }

    @Test func missingAPIKeyThrows() {
        #expect(throws: GoogleGenerativeAIRequestError.self) {
            _ = try GoogleGenerativeAIRequestBuilder.makeRequest(
                model: makeModel(baseURL: "https://api.google.com"),
                context: ChatContext(),
                options: ChatOptions()
            )
        }
    }

    // MARK: - Message and tool conversion

    @Test func convertsSystemUserImagesAssistantAndToolResult() {
        let model = makeModel(baseURL: "https://api.google.com")
        let body = GoogleGenerativeAIRequestBuilder.makeBody(
            model: model,
            context: ChatContext(
                systemPrompt: "sys",
                messages: [
                    .user(UserMessage(
                        content: .blocks([
                            .text(TextContent(text: "look")),
                            .image(ImageContent(data: "aGk=", mimeType: "image/png")),
                        ]),
                        timestamp: 0
                    )),
                    .assistant(AssistantMessage(
                        content: [
                            .text(TextContent(text: "answer")),
                            .toolCall(ToolCall(id: "call_1", name: "lookup", arguments: ["q": "swift"])),
                        ],
                        provider: "google",
                        model: "gemini-2.5-flash",
                        stopReason: .toolUse,
                        timestamp: 1
                    )),
                    .toolResult(ToolResultMessage(
                        toolCallId: "call_1",
                        toolName: "lookup",
                        text: "result",
                        timestamp: 2
                    )),
                ]
            ),
            options: ChatOptions()
        )

        #expect(body["systemInstruction"]["parts"][0]["text"] == .string("sys"))

        #expect(body["contents"][0]["role"] == .string("user"))
        #expect(body["contents"][0]["parts"][0]["text"] == .string("look"))
        #expect(body["contents"][0]["parts"][1]["inlineData"]["mimeType"] == .string("image/png"))
        #expect(body["contents"][0]["parts"][1]["inlineData"]["data"] == .string("aGk="))

        #expect(body["contents"][1]["role"] == .string("model"))
        #expect(body["contents"][1]["parts"][0]["text"] == .string("answer"))
        #expect(body["contents"][1]["parts"][1]["functionCall"]["name"] == .string("lookup"))
        #expect(body["contents"][1]["parts"][1]["functionCall"]["args"] == .object(["q": .string("swift")]))

        #expect(body["contents"][2]["role"] == .string("user"))
        #expect(body["contents"][2]["parts"][0]["functionResponse"]["name"] == .string("lookup"))
        #expect(
            body["contents"][2]["parts"][0]["functionResponse"]["response"]
                == .object(["output": .string("result")])
        )
    }

    @Test func groupsConsecutiveToolResultsIntoOneUserTurn() {
        let model = makeModel(baseURL: "https://api.google.com")
        let body = GoogleGenerativeAIRequestBuilder.makeBody(
            model: model,
            context: ChatContext(messages: [
                .toolResult(ToolResultMessage(toolCallId: "call_1", toolName: "a", text: "one", timestamp: 0)),
                .toolResult(ToolResultMessage(toolCallId: "call_2", toolName: "b", text: "two", timestamp: 1)),
            ]),
            options: ChatOptions()
        )
        #expect(body["contents"].arrayValue?.count == 1)
        #expect(body["contents"][0]["role"] == .string("user"))
        #expect(body["contents"][0]["parts"][0]["functionResponse"]["name"] == .string("a"))
        #expect(body["contents"][0]["parts"][1]["functionResponse"]["name"] == .string("b"))
    }

    @Test func errorToolResultUsesErrorKey() {
        let model = makeModel(baseURL: "https://api.google.com")
        let body = GoogleGenerativeAIRequestBuilder.makeBody(
            model: model,
            context: ChatContext(messages: [
                .toolResult(ToolResultMessage(
                    toolCallId: "call_1",
                    toolName: "lookup",
                    text: "boom",
                    isError: true,
                    timestamp: 0
                )),
            ]),
            options: ChatOptions()
        )
        #expect(
            body["contents"][0]["parts"][0]["functionResponse"]["response"]
                == .object(["error": .string("boom")])
        )
    }

    @Test func convertsToolsToFunctionDeclarationsAndStripsMetaKeys() throws {
        let schema = try JSONSchema(jsonValue: [
            "$schema": .string("http://json-schema.org/draft-07/schema#"),
            "$id": .string("urn:lookup"),
            "type": .string("object"),
            "properties": .object([
                "q": .object([
                    "$id": .string("urn:nested"),
                    "type": .string("string"),
                ]),
            ]),
            "required": .array([.string("q")]),
        ])
        let body = GoogleGenerativeAIRequestBuilder.makeBody(
            model: makeModel(baseURL: "https://api.google.com"),
            context: ChatContext(tools: [
                Tool(name: "lookup", description: "Look something up", parameters: schema),
            ]),
            options: ChatOptions()
        )

        let declaration = body["tools"][0]["functionDeclarations"][0]
        #expect(declaration["name"] == .string("lookup"))
        #expect(declaration["description"] == .string("Look something up"))
        #expect(declaration["parameters"]["type"] == .string("object"))
        #expect(declaration["parameters"]["required"] == .array([.string("q")]))
        #expect(declaration["parameters"]["$schema"].isNull)
        #expect(declaration["parameters"]["$id"].isNull)
        #expect(declaration["parameters"]["properties"]["q"]["$id"].isNull)
        #expect(declaration["parameters"]["properties"]["q"]["type"] == .string("string"))
    }

    // MARK: - Streaming

    @Test func streamsTextDeltasAndUsageMetadata() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            sse(candidateChunk(parts: [["text": .string("Hel")]])),
            sse(candidateChunk(parts: [["text": .string("lo")]])),
            sse([
                "candidates": .array([.object([
                    "content": .object(["parts": .array([])]),
                    "finishReason": .string("STOP"),
                ])]),
                "usageMetadata": .object([
                    "promptTokenCount": .int(10),
                    "candidatesTokenCount": .int(5),
                    "cachedContentTokenCount": .int(2),
                    "thoughtsTokenCount": .int(4),
                    "totalTokenCount": .int(17),
                ]),
            ]),
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: ChatContext(messages: [.user(UserMessage(content: "hi", timestamp: 0))]),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.started)
        #expect(recorder.thrown == nil)
        #expect(recorder.error == nil)
        #expect(recorder.text == "Hello")
        let done = try #require(recorder.done)
        #expect(done.content == [.text(TextContent(text: "Hello"))])
        #expect(done.stopReason == .stop)
        #expect(done.api == "google-generative-ai")
        #expect(done.provider == "google")
        #expect(done.model == "gemini-2.5-flash")
        // Usage: input = 10 - 2, output = 5 + 4, cacheRead = 2, reasoning = 4.
        #expect(done.usage.input == 8)
        #expect(done.usage.output == 9)
        #expect(done.usage.cacheRead == 2)
        #expect(done.usage.reasoning == 4)
        #expect(done.usage.totalTokens == 17)
    }

    @Test func streamsThinkingPartThenText() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            sse(candidateChunk(parts: [
                [
                    "thought": .bool(true),
                    "text": .string("pondering"),
                    "thoughtSignature": .string("c2ln"),
                ],
                ["text": .string("Answer")],
            ])),
            sse(candidateChunk(parts: [], finishReason: "STOP")),
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: ChatContext(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.thinking == "pondering")
        #expect(recorder.text == "Answer")
        let done = try #require(recorder.done)
        #expect(done.content == [
            .thinking(ThinkingContent(thinking: "pondering", thinkingSignature: "c2ln")),
            .text(TextContent(text: "Answer")),
        ])
        #expect(done.stopReason == .stop)
    }

    @Test func streamsFunctionCallAndOverridesStopReasonToToolUse() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            sse(candidateChunk(parts: [[
                "functionCall": .object([
                    "name": .string("get_weather"),
                    "args": .object(["city": .string("Paris")]),
                ]),
            ]])),
            sse(candidateChunk(parts: [], finishReason: "STOP")),
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: ChatContext(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.thrown == nil)
        #expect(recorder.toolCallDeltas.count == 1)
        #expect(recorder.toolCallDeltas.first?.index == 0)
        #expect(recorder.toolCallDeltas.first?.name == "get_weather")
        #expect(recorder.toolCallDeltas.first?.fragment == #"{"city":"Paris"}"#)

        let done = try #require(recorder.done)
        #expect(done.stopReason == .toolUse)
        #expect(done.content.count == 1)
        guard case .toolCall(let call) = done.content.first else {
            Issue.record("expected a tool call block")
            return
        }
        #expect(call.name == "get_weather")
        #expect(call.arguments == .object(["city": .string("Paris")]))
        #expect(!call.id.isEmpty)
    }

    @Test func mapsMaxTokensToLength() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            sse(candidateChunk(parts: [["text": .string("truncated")]], finishReason: "MAX_TOKENS")),
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: ChatContext(),
            options: ChatOptions(apiKey: "test")
        ))
        let done = try #require(recorder.done)
        #expect(done.stopReason == .length)
    }

    @Test func safetyFinishReasonSurfacesAsError() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            sse(candidateChunk(parts: [], finishReason: "SAFETY")),
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: ChatContext(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.done == nil)
        let error = try #require(recorder.error as? GoogleGenerativeAIStreamError)
        #expect(error == .providerError("Provider stopped with: SAFETY"))
    }

    @Test func streamWithoutFinishReasonThrows() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.stream([
            sse(candidateChunk(parts: [["text": .string("hi")]])),
        ]))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: ChatContext(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.done == nil)
        #expect(recorder.error as? GoogleGenerativeAIStreamError == .missingStopReason)
    }

    // MARK: - Non-streaming

    @Test func parsesNonStreamingCompletion() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(#"""
        {"responseId":"resp_2","candidates":[{"content":{"parts":[{"thought":true,"text":"think"},{"text":"Hello there"},{"functionCall":{"name":"lookup","args":{"q":"swift"}}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":4,"cachedContentTokenCount":2,"thoughtsTokenCount":3,"totalTokenCount":19}}
        """#))
        let message = try await makeProvider().complete(
            model: makeModel(baseURL: endpoint.baseURL),
            context: ChatContext(messages: [.user(UserMessage(content: "hi", timestamp: 0))]),
            options: ChatOptions(apiKey: "test")
        )

        #expect(message.api == "google-generative-ai")
        #expect(message.provider == "google")
        #expect(message.model == "gemini-2.5-flash")
        #expect(message.responseId == "resp_2")
        #expect(message.stopReason == .toolUse)
        #expect(message.content[0] == .thinking(ThinkingContent(thinking: "think")))
        #expect(message.content[1] == .text(TextContent(text: "Hello there")))
        guard case .toolCall(let call) = message.content[2] else {
            Issue.record("expected a tool call block")
            return
        }
        #expect(call.name == "lookup")
        #expect(call.arguments == .object(["q": .string("swift")]))
        #expect(message.usage.input == 10)
        #expect(message.usage.output == 7)
        #expect(message.usage.cacheRead == 2)
        #expect(message.usage.reasoning == 3)
        #expect(message.usage.totalTokens == 19)
    }

    @Test func parsesNonStreamingTextOnly() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(#"{"candidates":[{"content":{"parts":[{"text":"plain"}]},"finishReason":"STOP"}]}"#))
        let message = try await makeProvider().complete(
            model: makeModel(baseURL: endpoint.baseURL),
            context: ChatContext(),
            options: ChatOptions(apiKey: "test")
        )
        #expect(message.stopReason == .stop)
        #expect(message.content == [.text(TextContent(text: "plain"))])
    }

    // MARK: - Errors and retry

    @Test func nonRetryableHTTPErrorThrows() async {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(#"{"error":{"code":400,"message":"bad request"}}"#, statusCode: 400))
        do {
            _ = try await makeProvider(maxRetries: 3).complete(
                model: makeModel(baseURL: endpoint.baseURL),
                context: ChatContext(),
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

    @Test func streamingHTTPErrorSurfacesAsErrorEvent() async {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(#"{"error":{"message":"server error"}}"#, statusCode: 500))
        let recorder = await run(makeProvider().stream(
            model: makeModel(baseURL: endpoint.baseURL),
            context: ChatContext(),
            options: ChatOptions(apiKey: "test")
        ))

        #expect(recorder.done == nil)
        let error = try? #require(recorder.error as? ProviderHTTPError)
        #expect(error?.status == 500)
    }

    @Test func retries429ThenSucceeds() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(.json(
            #"{"error":{"message":"rate limited"}}"#,
            statusCode: 429,
            headers: ["retry-after-ms": "1"]
        ))
        endpoint.enqueue(.json(#"{"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}"#))
        let message = try await makeProvider(maxRetries: 1).complete(
            model: makeModel(baseURL: endpoint.baseURL),
            context: ChatContext(),
            options: ChatOptions(apiKey: "test")
        )
        #expect(message.content == [.text(TextContent(text: "ok"))])
        #expect(endpoint.requestCount == 2)
    }
}
