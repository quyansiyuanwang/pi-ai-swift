import Foundation
import Testing
@testable import PiAI

@Suite struct OpenAIRequestBuilderTests {
    private func makeModel(
        id: String = "gpt-4o-mini",
        provider: String = "openai",
        baseURL: String = "https://api.openai.com/v1",
        headers: [String: String] = [:]
    ) -> Model {
        Model(
            id: id,
            name: id,
            api: "openai-completions",
            provider: provider,
            baseURL: baseURL,
            contextWindow: 128_000,
            maxTokens: 16_384,
            reasoning: false,
            headers: headers
        )
    }

    private func makeOptions(
        apiKey: String = "test-key",
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        topP: Double? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        toolChoice: ToolChoice? = nil,
        headers: [String: String] = [:]
    ) -> ChatOptions {
        ChatOptions(
            apiKey: apiKey,
            temperature: temperature,
            maxTokens: maxTokens,
            topP: topP,
            frequencyPenalty: frequencyPenalty,
            presencePenalty: presencePenalty,
            toolChoice: toolChoice,
            headers: headers
        )
    }

    // MARK: - URL

    @Test func joinsBaseURLWithDefaultPath() throws {
        let url = try OpenAIRequestBuilder.resolveURL(baseURL: "https://api.example.com/v1", path: "chat/completions")
        #expect(url.absoluteString == "https://api.example.com/v1/chat/completions")
    }

    @Test func trimsTrailingSlash() throws {
        let url = try OpenAIRequestBuilder.resolveURL(baseURL: "https://api.example.com/v1/", path: "chat/completions")
        #expect(url.absoluteString == "https://api.example.com/v1/chat/completions")
    }

    @Test func doesNotDoubleAppendExistingPath() throws {
        let url = try OpenAIRequestBuilder.resolveURL(
            baseURL: "https://api.example.com/v1/chat/completions",
            path: "chat/completions"
        )
        #expect(url.absoluteString == "https://api.example.com/v1/chat/completions")
    }

    @Test func doesNotDoubleAppendExistingPathWithTrailingSlash() throws {
        let url = try OpenAIRequestBuilder.resolveURL(
            baseURL: "https://api.example.com/v1/chat/completions/",
            path: "chat/completions"
        )
        #expect(url.absoluteString == "https://api.example.com/v1/chat/completions")
    }

    @Test func emptyBaseURLThrows() {
        #expect(throws: OpenAIRequestError.self) {
            try OpenAIRequestBuilder.resolveURL(baseURL: "  ", path: "chat/completions")
        }
    }

    // MARK: - Headers

    @Test func addsAuthorizationHeaderFromAPIKey() throws {
        let request = try OpenAIRequestBuilder.makeRequest(
            model: makeModel(),
            context: ChatContext(),
            options: makeOptions(apiKey: "secret")
        )
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("pi (") == true)
    }

    @Test func missingAPIKeyThrows() {
        #expect(throws: OpenAIRequestError.self) {
            try OpenAIRequestBuilder.makeRequest(
                model: makeModel(provider: "custom"),
                context: ChatContext(),
                options: makeOptions(apiKey: "")
            )
        }
    }

    @Test func missingAPIKeyAllowedWithAuthorizationHeader() throws {
        let request = try OpenAIRequestBuilder.makeRequest(
            model: makeModel(provider: "custom"),
            context: ChatContext(),
            options: makeOptions(apiKey: "", headers: ["Authorization": "Bearer inline"])
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer inline")
    }

    @Test func missingAPIKeyAllowedWithCfAigAuthorizationHeader() throws {
        let request = try OpenAIRequestBuilder.makeRequest(
            model: makeModel(provider: "cloudflare"),
            context: ChatContext(),
            options: makeOptions(apiKey: "", headers: ["cf-aig-authorization": "Bearer cf"])
        )
        #expect(request.value(forHTTPHeaderField: "cf-aig-authorization") == "Bearer cf")
    }

    @Test func optionsHeadersOverrideModelHeadersCaseInsensitively() throws {
        let request = try OpenAIRequestBuilder.makeRequest(
            model: makeModel(headers: ["X-A": "model", "X-B": "model"]),
            context: ChatContext(),
            options: makeOptions(headers: ["x-a": "options"])
        )
        #expect(request.value(forHTTPHeaderField: "X-A") == "options")
        #expect(request.value(forHTTPHeaderField: "X-B") == "model")
    }

    // MARK: - Body

    @Test func bodyHasCoreFields() {
        let body = OpenAIRequestBuilder.makeBody(
            model: makeModel(),
            context: ChatContext(messages: [.user(UserMessage(content: "hi", timestamp: 0))]),
            options: makeOptions(temperature: 0.5, maxTokens: 128)
        )
        #expect(body["model"] == .string("gpt-4o-mini"))
        #expect(body["stream"] == .bool(false))
        #expect(body["max_tokens"] == .int(128))
        #expect(body["temperature"] == .number(0.5))
        #expect(body["messages"][0]["role"] == .string("user"))
        #expect(body["messages"][0]["content"] == .string("hi"))
    }

    @Test func bodyOmitsOptionalFields() {
        let body = OpenAIRequestBuilder.makeBody(
            model: makeModel(),
            context: ChatContext(),
            options: makeOptions()
        )
        #expect(body["max_tokens"].isNull)
        #expect(body["temperature"].isNull)
        #expect(body["top_p"].isNull)
        #expect(body["frequency_penalty"].isNull)
        #expect(body["presence_penalty"].isNull)
        #expect(body["tools"].isNull)
    }

    @Test func bodyForwardsSamplingParameters() {
        let body = OpenAIRequestBuilder.makeBody(
            model: makeModel(),
            context: ChatContext(messages: [.user(UserMessage(content: "hi", timestamp: 0))]),
            options: makeOptions(topP: 0.9, frequencyPenalty: 0.4, presencePenalty: -0.2)
        )
        #expect(body["top_p"] == .number(0.9))
        #expect(body["frequency_penalty"] == .number(0.4))
        #expect(body["presence_penalty"] == .number(-0.2))
    }

    @Test func toolChoiceIsOmittedByDefault() {
        let body = OpenAIRequestBuilder.makeBody(
            model: makeModel(),
            context: ChatContext(tools: [Tool(name: "ping", description: "Ping", parameters: .object())]),
            options: makeOptions()
        )
        #expect(body["tool_choice"].isNull)
    }

    @Test func toolChoiceStringFormsEncodeAsStrings() {
        for (choice, expected) in [
            (ToolChoice.auto, JSONValue.string("auto")),
            (ToolChoice.none, JSONValue.string("none")),
            (ToolChoice.required, JSONValue.string("required")),
        ] {
            let body = OpenAIRequestBuilder.makeBody(
                model: makeModel(),
                context: ChatContext(),
                options: makeOptions(toolChoice: choice)
            )
            #expect(body["tool_choice"] == expected)
        }
    }

    @Test func toolChoiceFunctionEncodesObject() {
        let body = OpenAIRequestBuilder.makeBody(
            model: makeModel(),
            context: ChatContext(),
            options: makeOptions(toolChoice: .function(name: "lookup"))
        )
        #expect(body["tool_choice"] == .object([
            "type": .string("function"),
            "function": .object(["name": .string("lookup")]),
        ]))
    }

    @Test func toolChoiceCodableRoundTrip() throws {
        for choice in [ToolChoice.auto, .none, .required, .function(name: "lookup")] {
            let data = try JSONEncoder().encode(choice)
            let decoded = try JSONDecoder().decode(ToolChoice.self, from: data)
            #expect(decoded == choice)
        }
        #expect(try JSONDecoder().decode(ToolChoice.self, from: Data(#""auto""#.utf8)) == .auto)
    }

    @Test func systemPromptPrecedesSystemMessages() {
        let context = ChatContext(
            systemPrompt: "top level",
            messages: [
                .system(SystemMessage(content: "mid convo", timestamp: 1)),
                .user(UserMessage(content: "hi", timestamp: 2)),
            ]
        )
        let body = OpenAIRequestBuilder.makeBody(model: makeModel(), context: context, options: makeOptions())
        #expect(body["messages"][0]["role"] == .string("system"))
        #expect(body["messages"][0]["content"] == .string("top level"))
        #expect(body["messages"][1]["role"] == .string("system"))
        #expect(body["messages"][1]["content"] == .string("mid convo"))
        #expect(body["messages"][2]["role"] == .string("user"))
    }

    @Test func userImageBlocksBecomeDataURLs() {
        let context = ChatContext(messages: [
            .user(UserMessage(
                content: .blocks([
                    .text(TextContent(text: "describe")),
                    .image(ImageContent(data: "aGk=", mimeType: "image/png")),
                ]),
                timestamp: 0
            )),
        ])
        let body = OpenAIRequestBuilder.makeBody(model: makeModel(), context: context, options: makeOptions())
        let content = body["messages"][0]["content"]
        #expect(content[0]["type"] == .string("text"))
        #expect(content[0]["text"] == .string("describe"))
        #expect(content[1]["type"] == .string("image_url"))
        #expect(content[1]["image_url"]["url"] == .string("data:image/png;base64,aGk="))
    }

    @Test func emptyUserBlocksMessageIsSkipped() {
        let context = ChatContext(messages: [
            .user(UserMessage(content: .blocks([.text(TextContent(text: ""))]), timestamp: 0)),
        ])
        let body = OpenAIRequestBuilder.makeBody(model: makeModel(), context: context, options: makeOptions())
        #expect(body["messages"].arrayValue?.isEmpty == true)
    }

    @Test func assistantToolCallHasNullContentAndSerializedArguments() {
        let context = ChatContext(messages: [
            .assistant(AssistantMessage(
                content: [.toolCall(ToolCall(id: "call_1", name: "lookup", arguments: ["q": "swift"]))],
                stopReason: .toolUse,
                timestamp: 0
            )),
        ])
        let body = OpenAIRequestBuilder.makeBody(model: makeModel(), context: context, options: makeOptions())
        let assistant = body["messages"][0]
        #expect(assistant["role"] == .string("assistant"))
        #expect(assistant["content"].isNull)
        #expect(assistant["tool_calls"][0]["id"] == .string("call_1"))
        #expect(assistant["tool_calls"][0]["type"] == .string("function"))
        #expect(assistant["tool_calls"][0]["function"]["name"] == .string("lookup"))
        let argumentsString = assistant["tool_calls"][0]["function"]["arguments"].stringValue ?? ""
        let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(argumentsString.utf8))
        #expect(parsed?["q"] == .string("swift"))
    }

    @Test func assistantReasoningContentFromThinking() {
        let context = ChatContext(messages: [
            .assistant(AssistantMessage(
                content: [
                    .thinking(ThinkingContent(thinking: "let me think")),
                    .text(TextContent(text: "answer")),
                ],
                stopReason: .stop,
                timestamp: 0
            )),
        ])
        let body = OpenAIRequestBuilder.makeBody(model: makeModel(), context: context, options: makeOptions())
        let assistant = body["messages"][0]
        #expect(assistant["content"] == .string("answer"))
        #expect(assistant["reasoning_content"] == .string("let me think"))
    }

    @Test func thinkingOnlyAssistantMessageIsSkipped() {
        let context = ChatContext(messages: [
            .assistant(AssistantMessage(
                content: [.thinking(ThinkingContent(thinking: "just thinking"))],
                stopReason: .stop,
                timestamp: 0
            )),
        ])
        let body = OpenAIRequestBuilder.makeBody(model: makeModel(), context: context, options: makeOptions())
        #expect(body["messages"].arrayValue?.isEmpty == true)
    }

    @Test func toolResultBecomesToolRole() {
        let context = ChatContext(messages: [
            .toolResult(ToolResultMessage(toolCallId: "call_1", toolName: "lookup", text: "Paris", timestamp: 0)),
        ])
        let body = OpenAIRequestBuilder.makeBody(model: makeModel(), context: context, options: makeOptions())
        let message = body["messages"][0]
        #expect(message["role"] == .string("tool"))
        #expect(message["content"] == .string("Paris"))
        #expect(message["tool_call_id"] == .string("call_1"))
    }

    @Test func emptyToolResultUsesPlaceholder() {
        let context = ChatContext(messages: [
            .toolResult(ToolResultMessage(toolCallId: "call_1", toolName: "lookup", content: [], timestamp: 0)),
        ])
        let body = OpenAIRequestBuilder.makeBody(model: makeModel(), context: context, options: makeOptions())
        #expect(body["messages"][0]["content"] == .string("(no tool output)"))
    }

    @Test func emptyToolsOmittedWithoutHistory() {
        let body = OpenAIRequestBuilder.makeBody(
            model: makeModel(),
            context: ChatContext(tools: []),
            options: makeOptions()
        )
        #expect(body["tools"].isNull)
    }

    @Test func emptyToolsArraySentWithToolHistory() {
        let context = ChatContext(
            messages: [
                .assistant(AssistantMessage(
                    content: [.toolCall(ToolCall(id: "t1", name: "noop"))],
                    stopReason: .toolUse,
                    timestamp: 0
                )),
                .toolResult(ToolResultMessage(toolCallId: "t1", toolName: "noop", text: "done", timestamp: 1)),
            ],
            tools: []
        )
        let body = OpenAIRequestBuilder.makeBody(model: makeModel(), context: context, options: makeOptions())
        #expect(body["tools"] == .array([]))
    }

    @Test func toolSerializationShape() {
        let tool = Tool(
            name: "lookup",
            description: "Look something up",
            parameters: .object(properties: ["q": .string()], required: ["q"])
        )
        let body = OpenAIRequestBuilder.makeBody(
            model: makeModel(),
            context: ChatContext(tools: [tool]),
            options: makeOptions()
        )
        let serialized = body["tools"][0]
        #expect(serialized["type"] == .string("function"))
        #expect(serialized["function"]["name"] == .string("lookup"))
        #expect(serialized["function"]["description"] == .string("Look something up"))
        #expect(serialized["function"]["parameters"]["type"] == .string("object"))
        #expect(serialized["function"]["parameters"]["properties"]["q"]["type"] == .string("string"))
        #expect(serialized["function"]["parameters"]["required"] == .array([.string("q")]))
    }

    @Test func requestBodyIsEncodableJSON() throws {
        let request = try OpenAIRequestBuilder.makeRequest(
            model: makeModel(),
            context: ChatContext(
                systemPrompt: "be helpful",
                messages: [.user(UserMessage(content: "hello", timestamp: 0))],
                tools: [Tool(name: "ping", description: "Ping", parameters: .object())]
            ),
            options: makeOptions(maxTokens: 64)
        )
        let body = try #require(request.httpBody)
        let value = try JSONDecoder().decode(JSONValue.self, from: body)
        #expect(value["stream"] == .bool(false))
        #expect(value["model"] == .string("gpt-4o-mini"))
        #expect(value["tools"][0]["function"]["name"] == .string("ping"))
    }

    @Test func sanitizesUnpairedSurrogatesNotApplicableToNormalStrings() {
        #expect(SanitizeUnicode.sanitize("hello 🙈 world") == "hello 🙈 world")
        let loneHigh = String(decoding: [0x41, 0xD83D, 0x42] as [UInt16], as: UTF16.self)
        // String decoding replaces invalid UTF-16 with U+FFFD, so sanitize is idempotent.
        #expect(SanitizeUnicode.sanitize(loneHigh) == loneHigh)
    }
}
