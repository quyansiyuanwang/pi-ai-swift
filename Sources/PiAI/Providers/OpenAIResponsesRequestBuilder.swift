import Foundation

/// Builds OpenAI Responses API requests.
///
/// Faithful to the request-shaping subset of upstream
/// `api/openai-responses.ts` (`buildParams` + `convertResponsesMessages` +
/// `convertResponsesTools`), with the documented simplifications: no compat
/// flags, prompt caching, session affinity, ChatGPT sign-in, grammar tools or
/// service tiers.
public enum OpenAIResponsesRequestBuilder {
    /// OpenAI Responses rejects `max_output_tokens` below this value.
    /// See https://github.com/earendil-works/pi/issues/6265.
    public static let minOutputTokens = 16

    /// Builds a `POST` request for the Responses API `path` (default `responses`).
    public static func makeRequest(
        model: Model,
        context: ChatContext,
        options: ChatOptions,
        streaming: Bool = false,
        reasoningEffort: String? = nil,
        path: String = "responses"
    ) throws -> URLRequest {
        let url = try OpenAIRequestBuilder.resolveURL(baseURL: model.baseURL, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": PiUserAgent.current,
        ]
        for (name, value) in model.headers {
            setHeader(&headers, name: name, value: value)
        }
        for (name, value) in options.headers {
            setHeader(&headers, name: name, value: value)
        }

        if !options.apiKey.isEmpty {
            setHeader(&headers, name: "Authorization", value: "Bearer \(options.apiKey)")
        } else if !hasHeader(headers, "authorization") && !hasHeader(headers, "cf-aig-authorization") {
            throw OpenAIRequestError.missingAPIKey(provider: model.provider)
        }

        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(
            makeBody(
                model: model,
                context: context,
                options: options,
                streaming: streaming,
                reasoningEffort: reasoningEffort
            )
        )
        return request
    }

    /// Builds the JSON request body.
    public static func makeBody(
        model: Model,
        context: ChatContext,
        options: ChatOptions,
        streaming: Bool = false,
        reasoningEffort: String? = nil
    ) -> JSONValue {
        var body: JSONObject = [
            "model": .string(model.id),
            "input": .array(convertMessages(model: model, context: context)),
            "stream": .bool(streaming),
            "store": .bool(false),
        ]

        if let maxTokens = options.maxTokens {
            body["max_output_tokens"] = .int(max(maxTokens, minOutputTokens))
        }
        if let temperature = options.temperature {
            body["temperature"] = .number(temperature)
        }
        if let topP = options.topP {
            body["top_p"] = .number(topP)
        }

        if !context.tools.isEmpty {
            body["tools"] = .array(context.tools.map(convertTool))
        }

        if let toolChoice = options.toolChoice {
            body["tool_choice"] = convertToolChoice(toolChoice)
        }

        if let reasoningEffort, !reasoningEffort.isEmpty {
            body["reasoning"] = .object(["effort": .string(reasoningEffort)])
        }

        return .object(body)
    }

    // MARK: - Message conversion

    /// Converts the transcript into Responses API `input` items.
    ///
    /// Mirrors upstream `convertResponsesMessages` for the supported subset:
    /// system/developer instructions, user `input_text`/`input_image` parts,
    /// assistant `output_text` messages and `function_call` items, and
    /// `function_call_output` tool results.
    static func convertMessages(model: Model, context: ChatContext) -> [JSONValue] {
        var items: [JSONValue] = []
        let instructionRole = model.reasoning ? "developer" : "system"

        if let systemPrompt = context.systemPrompt, !systemPrompt.isEmpty {
            items.append(instructionItem(role: instructionRole, text: systemPrompt))
        }

        for message in context.messages {
            switch message {
            case .system(let system):
                let text = text(of: system.content)
                if !text.isEmpty {
                    items.append(instructionItem(role: instructionRole, text: text))
                }
            case .user(let user):
                if let value = convertUser(user) { items.append(value) }
            case .assistant(let assistant):
                items.append(contentsOf: convertAssistant(assistant))
            case .toolResult(let toolResult):
                items.append(convertToolResult(model: model, toolResult))
            }
        }

        return items
    }

    private static func instructionItem(role: String, text: String) -> JSONValue {
        .object([
            "role": .string(role),
            "content": .string(SanitizeUnicode.sanitize(text)),
        ])
    }

    private static func convertUser(_ user: UserMessage) -> JSONValue? {
        switch user.content {
        case .text(let string):
            return .object([
                "role": .string("user"),
                "content": .array([
                    .object([
                        "type": .string("input_text"),
                        "text": .string(SanitizeUnicode.sanitize(string)),
                    ]),
                ]),
            ])
        case .blocks(let blocks):
            var parts: [JSONValue] = []
            for block in blocks {
                switch block {
                case .text(let content):
                    parts.append(.object([
                        "type": .string("input_text"),
                        "text": .string(SanitizeUnicode.sanitize(content.text)),
                    ]))
                case .image(let image):
                    parts.append(.object([
                        "type": .string("input_image"),
                        "image_url": .string("data:\(image.mimeType);base64,\(image.data)"),
                    ]))
                case .thinking, .toolCall:
                    continue
                }
            }
            guard !parts.isEmpty else { return nil }
            return .object([
                "role": .string("user"),
                "content": .array(parts),
            ])
        }
    }

    private static func convertAssistant(_ assistant: AssistantMessage) -> [JSONValue] {
        var output: [JSONValue] = []
        for block in assistant.content {
            switch block {
            case .thinking(let content):
                // Replay a serialized reasoning item when a signature is present.
                guard let signature = content.thinkingSignature,
                      let parsed = JSONParse.parse(signature),
                      parsed.objectValue != nil else {
                    continue
                }
                output.append(parsed)
            case .text(let content):
                output.append(.object([
                    "type": .string("message"),
                    "role": .string("assistant"),
                    "content": .array([
                        .object([
                            "type": .string("output_text"),
                            "text": .string(SanitizeUnicode.sanitize(content.text)),
                        ]),
                    ]),
                    "status": .string("completed"),
                ]))
            case .toolCall(let call):
                output.append(.object([
                    "type": .string("function_call"),
                    "call_id": .string(callId(of: call.id)),
                    "name": .string(call.name),
                    "arguments": .string(jsonString(call.arguments)),
                ]))
            case .image:
                continue
            }
        }
        return output
    }

    private static func convertToolResult(model: Model, _ toolResult: ToolResultMessage) -> JSONValue {
        .object([
            "type": .string("function_call_output"),
            "call_id": .string(callId(of: toolResult.toolCallId)),
            "output": convertToolResultOutput(model: model, content: toolResult.content),
        ])
    }

    private static func convertToolResultOutput(model: Model, content: [ContentBlock]) -> JSONValue {
        let text = content.compactMap { block -> String? in
            guard case .text(let value) = block else { return nil }
            return value.text
        }.joined(separator: "\n")
        let images = content.compactMap { block -> ImageContent? in
            guard case .image(let value) = block else { return nil }
            return value
        }
        let hasText = !text.isEmpty

        if images.isEmpty || !model.input.contains(.image) {
            if hasText { return .string(SanitizeUnicode.sanitize(text)) }
            return .string(images.isEmpty ? "(no tool output)" : "(see attached image)")
        }

        var parts: [JSONValue] = []
        if hasText {
            parts.append(.object([
                "type": .string("input_text"),
                "text": .string(SanitizeUnicode.sanitize(text)),
            ]))
        }
        for image in images {
            parts.append(.object([
                "type": .string("input_image"),
                "detail": .string("auto"),
                "image_url": .string("data:\(image.mimeType);base64,\(image.data)"),
            ]))
        }
        return .array(parts)
    }

    // MARK: - Tool conversion

    /// Converts a tool declaration to the Responses API `function` shape:
    /// `{ type: "function", name, description, parameters, strict: false }`.
    static func convertTool(_ tool: Tool) -> JSONValue {
        .object([
            "type": .string("function"),
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": tool.parameters.makeJSONValue(),
            "strict": .bool(false),
        ])
    }

    static func convertToolChoice(_ choice: ToolChoice) -> JSONValue {
        switch choice {
        case .auto: return .string("auto")
        case .none: return .string("none")
        case .required: return .string("required")
        case .function(let name):
            return .object([
                "type": .string("function"),
                "name": .string(name),
            ])
        }
    }

    // MARK: - Helpers

    /// Extracts the provider `call_id` from a persisted tool-call id. Upstream
    /// stores `call_id|item_id`; the simplified port only persists the call id
    /// but tolerates the composite form for forward compatibility.
    private static func callId(of id: String) -> String {
        id.split(separator: "|", maxSplits: 1).first.map(String.init) ?? id
    }

    private static func text(of content: MessageContent) -> String {
        switch content {
        case .text(let string):
            return string
        case .blocks(let blocks):
            return blocks.compactMap { block -> String? in
                guard case .text(let value) = block else { return nil }
                return value.text
            }.joined()
        }
    }

    private static func jsonString(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func setHeader(_ headers: inout [String: String], name: String, value: String) {
        if let existing = headers.keys.first(where: { $0.lowercased() == name.lowercased() }) {
            headers.removeValue(forKey: existing)
        }
        headers[name] = value
    }

    private static func hasHeader(_ headers: [String: String], _ name: String) -> Bool {
        let expected = name.lowercased()
        for (key, value) in headers where key.lowercased() == expected {
            if !value.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        }
        return false
    }
}
