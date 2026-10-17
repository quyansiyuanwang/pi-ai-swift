import Foundation

/// Errors produced while building an OpenAI-compatible request.
public enum OpenAIRequestError: Error, Sendable, Equatable, LocalizedError {
    case missingAPIKey(provider: String)
    case invalidBaseURL(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "No API key for provider: \(provider)"
        case .invalidBaseURL(let baseURL):
            return "Invalid base URL: \(baseURL)"
        }
    }
}

/// Builds non-streaming OpenAI Chat Completions requests.
///
/// Faithful to the non-streaming subset of upstream
/// `api/openai-completions.ts` (`buildParams` + `convertMessages` +
/// `convertTools`), with the documented simplifications: `stream: false`,
/// `max_tokens` (never `max_completion_tokens`), and no compat/vendor fields.
public enum OpenAIRequestBuilder {
    /// Builds a `POST` request for the chat completions `path`.
    public static func makeRequest(
        model: Model,
        context: ChatContext,
        options: ChatOptions,
        path: String = "chat/completions",
        streaming: Bool = false,
        reasoningEffort: String? = nil
    ) throws -> URLRequest {
        let url = try resolveURL(baseURL: model.baseURL, path: path)
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
    ///
    /// `streaming` toggles `stream` and requests incremental usage reporting
    /// (`stream_options.include_usage`), matching upstream's
    /// `supportsUsageInStreaming` default.
    public static func makeBody(
        model: Model,
        context: ChatContext,
        options: ChatOptions,
        streaming: Bool = false,
        reasoningEffort: String? = nil
    ) -> JSONValue {
        var body: JSONObject = [
            "model": .string(model.id),
            "messages": .array(convertMessages(context)),
            "stream": .bool(streaming),
        ]

        if streaming {
            body["stream_options"] = .object(["include_usage": .bool(true)])
        }

        if let maxTokens = options.maxTokens {
            body["max_tokens"] = .int(maxTokens)
        }
        if let temperature = options.temperature {
            body["temperature"] = .number(temperature)
        }
        if let topP = options.topP {
            body["top_p"] = .number(topP)
        }
        if let frequencyPenalty = options.frequencyPenalty {
            body["frequency_penalty"] = .number(frequencyPenalty)
        }
        if let presencePenalty = options.presencePenalty {
            body["presence_penalty"] = .number(presencePenalty)
        }

        if let reasoningEffort, !reasoningEffort.isEmpty {
            body["reasoning_effort"] = .string(reasoningEffort)
        }

        if !context.tools.isEmpty {
            body["tools"] = .array(context.tools.map(convertTool))
        } else if hasToolHistory(context.messages) {
            // Anthropic (via LiteLLM/proxy) requires `tools` when the transcript
            // contains tool calls/results, even when no tools remain declared.
            body["tools"] = .array([])
        }

        if let toolChoice = options.toolChoice {
            body["tool_choice"] = toolChoice.jsonValue
        }

        return .object(body)
    }

    // MARK: - URL

    /// Joins `baseURL` with `path`, trimming trailing slashes and avoiding a
    /// duplicated path suffix (e.g. a base URL already ending in
    /// `/chat/completions`).
    static func resolveURL(baseURL: String, path: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }

        guard !base.isEmpty,
              let url = URL(string: base),
              url.scheme != nil,
              url.host != nil else {
            throw OpenAIRequestError.invalidBaseURL(baseURL)
        }

        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if suffix.isEmpty || base.hasSuffix("/" + suffix) {
            return url
        }

        guard let fullURL = URL(string: base + "/" + suffix) else {
            throw OpenAIRequestError.invalidBaseURL(baseURL)
        }
        return fullURL
    }

    // MARK: - Headers

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

    // MARK: - Messages

    private static func convertMessages(_ context: ChatContext) -> [JSONValue] {
        var messages: [JSONValue] = []

        if let systemPrompt = context.systemPrompt, !systemPrompt.isEmpty {
            messages.append(.object([
                "role": .string("system"),
                "content": .string(SanitizeUnicode.sanitize(systemPrompt)),
            ]))
        }

        for message in context.messages {
            switch message {
            case .system(let system):
                let text = text(of: system.content)
                if !text.isEmpty {
                    messages.append(.object([
                        "role": .string("system"),
                        "content": .string(SanitizeUnicode.sanitize(text)),
                    ]))
                }
            case .user(let user):
                if let value = convertUser(user) { messages.append(value) }
            case .assistant(let assistant):
                if let value = convertAssistant(assistant) { messages.append(value) }
            case .toolResult(let toolResult):
                messages.append(convertToolResult(toolResult))
            }
        }

        return messages
    }

    private static func convertUser(_ user: UserMessage) -> JSONValue? {
        switch user.content {
        case .text(let string):
            return .object([
                "role": .string("user"),
                "content": .string(SanitizeUnicode.sanitize(string)),
            ])
        case .blocks(let blocks):
            var parts: [JSONValue] = []
            for block in blocks {
                switch block {
                case .text(let content):
                    guard !content.text.isEmpty else { continue }
                    parts.append(.object([
                        "type": .string("text"),
                        "text": .string(SanitizeUnicode.sanitize(content.text)),
                    ]))
                case .image(let image):
                    parts.append(.object([
                        "type": .string("image_url"),
                        "image_url": .object([
                            "url": .string("data:\(image.mimeType);base64,\(image.data)"),
                        ]),
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

    private static func convertAssistant(_ assistant: AssistantMessage) -> JSONValue? {
        let textParts = assistant.content.compactMap { block -> String? in
            guard case .text(let content) = block else { return nil }
            guard !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return SanitizeUnicode.sanitize(content.text)
        }
        let thinkingParts = assistant.content.compactMap { block -> String? in
            guard case .thinking(let content) = block else { return nil }
            guard !content.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return SanitizeUnicode.sanitize(content.thinking)
        }
        let toolCalls = assistant.content.compactMap { block -> ToolCall? in
            guard case .toolCall(let call) = block else { return nil }
            return call
        }

        let text = textParts.joined()
        // Skip assistant messages without user-visible content or tool calls.
        if text.isEmpty && toolCalls.isEmpty { return nil }

        var object: JSONObject = ["role": .string("assistant")]
        object["content"] = text.isEmpty ? .null : .string(text)
        if !thinkingParts.isEmpty {
            object["reasoning_content"] = .string(thinkingParts.joined(separator: "\n"))
        }
        if !toolCalls.isEmpty {
            object["tool_calls"] = .array(toolCalls.map { call in
                .object([
                    "id": .string(call.id),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(call.name),
                        "arguments": .string(jsonString(call.arguments)),
                    ]),
                ])
            })
        }
        return .object(object)
    }

    private static func convertToolResult(_ toolResult: ToolResultMessage) -> JSONValue {
        let text = toolResult.content.compactMap { block -> String? in
            guard case .text(let content) = block else { return nil }
            return content.text
        }.joined(separator: "\n")
        let result = text.isEmpty ? "(no tool output)" : SanitizeUnicode.sanitize(text)
        return .object([
            "role": .string("tool"),
            "content": .string(result),
            "tool_call_id": .string(toolResult.toolCallId),
        ])
    }

    private static func text(of content: MessageContent) -> String {
        switch content {
        case .text(let string):
            return string
        case .blocks(let blocks):
            return blocks.compactMap { block -> String? in
                guard case .text(let content) = block else { return nil }
                return content.text
            }.joined()
        }
    }

    // MARK: - Tools

    private static func convertTool(_ tool: Tool) -> JSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.parameters.makeJSONValue(),
            ]),
        ])
    }

    private static func hasToolHistory(_ messages: [Message]) -> Bool {
        for message in messages {
            switch message {
            case .toolResult:
                return true
            case .assistant(let assistant):
                if assistant.content.contains(where: { block in
                    if case .toolCall = block { return true }
                    return false
                }) {
                    return true
                }
            case .system, .user:
                continue
            }
        }
        return false
    }

    // MARK: - Helpers

    private static func jsonString(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
