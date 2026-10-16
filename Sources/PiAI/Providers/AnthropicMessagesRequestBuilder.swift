import Foundation

/// Builds Anthropic Messages API requests.
///
/// Swift port of the request-shaping subset of upstream
/// `api/anthropic-messages.ts` (`buildParams` + `convertMessages` +
/// `convertTools` + `convertContentBlocks`). Compat flags, prompt caching,
/// beta headers, Bedrock/Vertex variants and count-tokens are intentionally
/// out of scope.
public enum AnthropicMessagesRequestBuilder {
    /// The required Anthropic API version header value.
    public static let apiVersion = "2023-06-01"

    /// Fallback `max_tokens` when ``ChatOptions/maxTokens`` is not set.
    ///
    /// Anthropic requires the field, so a value is always sent. Upstream falls
    /// back to `model.maxTokens`; this subset uses a fixed, documented default
    /// instead (see `docs/PORTING.md`).
    public static let defaultMaxTokens = 4096

    /// Builds a `POST {baseURL}/v1/messages` request.
    public static func makeRequest(
        model: Model,
        context: ChatContext,
        options: ChatOptions,
        streaming: Bool = false,
        reasoningBudgetTokens: Int? = nil
    ) throws -> URLRequest {
        let url = try resolveURL(baseURL: model.baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "anthropic-version": apiVersion,
            "User-Agent": PiUserAgent.current,
        ]
        for (name, value) in model.headers {
            setHeader(&headers, name: name, value: value)
        }
        for (name, value) in options.headers {
            setHeader(&headers, name: name, value: value)
        }

        if !options.apiKey.isEmpty {
            setHeader(&headers, name: "x-api-key", value: options.apiKey)
        } else if !hasHeader(headers, "x-api-key") {
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
                reasoningBudgetTokens: reasoningBudgetTokens
            )
        )
        return request
    }

    /// Builds the JSON request body. `max_tokens` is always present.
    public static func makeBody(
        model: Model,
        context: ChatContext,
        options: ChatOptions,
        streaming: Bool = false,
        reasoningBudgetTokens: Int? = nil
    ) -> JSONValue {
        var body: JSONObject = [
            "model": .string(model.id),
            "max_tokens": .int(options.maxTokens ?? defaultMaxTokens),
            "messages": .array(convertMessages(context)),
            "stream": .bool(streaming),
        ]

        if let system = convertSystem(context) {
            body["system"] = system
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
        if let reasoningBudgetTokens {
            body["thinking"] = .object([
                "type": .string("enabled"),
                "budget_tokens": .int(reasoningBudgetTokens),
            ])
        }

        return .object(body)
    }

    // MARK: - URL

    /// Joins `baseURL` with the Messages path, appending `/v1/messages` and
    /// avoiding a duplicated `/v1` segment when the base URL already contains
    /// it.
    static func resolveURL(baseURL: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }

        guard !base.isEmpty,
              let url = URL(string: base),
              url.scheme != nil,
              url.host != nil else {
            throw OpenAIRequestError.invalidBaseURL(baseURL)
        }

        if base.hasSuffix("/v1/messages") { return url }

        let full = base.hasSuffix("/v1") ? base + "/messages" : base + "/v1/messages"
        guard let fullURL = URL(string: full) else {
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

    // MARK: - System

    /// Builds the top-level `system` block array from the context system prompt
    /// and any `system` messages.
    static func convertSystem(_ context: ChatContext) -> JSONValue? {
        var blocks: [JSONValue] = []

        if let systemPrompt = context.systemPrompt,
           !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(textBlock(systemPrompt))
        }

        for message in context.messages {
            guard case .system(let system) = message else { continue }
            let text = text(of: system.content)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(textBlock(text))
            }
        }

        guard !blocks.isEmpty else { return nil }
        return .array(blocks)
    }

    private static func textBlock(_ text: String) -> JSONValue {
        .object([
            "type": .string("text"),
            "text": .string(SanitizeUnicode.sanitize(text)),
        ])
    }

    // MARK: - Messages

    /// Converts the transcript into Anthropic `messages`, dropping `system`
    /// messages (folded into the top-level `system`) and grouping consecutive
    /// tool results into one user turn.
    static func convertMessages(_ context: ChatContext) -> [JSONValue] {
        var messages: [JSONValue] = []
        let source = context.messages
        var index = 0

        while index < source.count {
            switch source[index] {
            case .system:
                index += 1

            case .user(let user):
                if let value = convertUser(user) { messages.append(value) }
                index += 1

            case .assistant(let assistant):
                if let value = convertAssistant(assistant) { messages.append(value) }
                index += 1

            case .toolResult:
                // Anthropic requires each `tool_result` to immediately follow
                // its `tool_use`; consecutive results share one user turn.
                var blocks: [JSONValue] = []
                while index < source.count, case .toolResult(let result) = source[index] {
                    blocks.append(convertToolResult(result))
                    index += 1
                }
                messages.append(.object([
                    "role": .string("user"),
                    "content": .array(blocks),
                ]))
            }
        }

        return messages
    }

    private static func convertUser(_ user: UserMessage) -> JSONValue? {
        switch user.content {
        case .text(let string):
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .object([
                "role": .string("user"),
                "content": .array([textBlock(string)]),
            ])

        case .blocks(let blocks):
            var parts: [JSONValue] = []
            for block in blocks {
                switch block {
                case .text(let content):
                    guard !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    parts.append(textBlock(content.text))
                case .image(let image):
                    parts.append(imageBlock(image))
                case .thinking, .toolCall:
                    continue
                }
            }
            guard !parts.isEmpty else { return nil }
            if !parts.contains(where: { $0["type"].stringValue == "text" }) {
                parts.insert(textBlock("(see attached image)"), at: 0)
            }
            return .object([
                "role": .string("user"),
                "content": .array(parts),
            ])
        }
    }

    private static func convertAssistant(_ assistant: AssistantMessage) -> JSONValue? {
        var blocks: [JSONValue] = []
        for block in assistant.content {
            switch block {
            case .text(let content):
                guard !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                blocks.append(textBlock(content.text))

            case .thinking(let content):
                if content.redacted == true, let signature = content.thinkingSignature, !signature.isEmpty {
                    blocks.append(.object([
                        "type": .string("redacted_thinking"),
                        "data": .string(signature),
                    ]))
                    continue
                }
                let thinking = SanitizeUnicode.sanitize(content.thinking)
                let signature = content.thinkingSignature ?? ""
                let hasSignature = !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasSignature { continue }
                if hasSignature {
                    blocks.append(.object([
                        "type": .string("thinking"),
                        "thinking": .string(thinking),
                        "signature": .string(signature),
                    ]))
                } else {
                    // A thinking block without a signature cannot be replayed to
                    // Anthropic; downgrade it to plain text (upstream behavior).
                    blocks.append(textBlock(thinking))
                }

            case .toolCall(let call):
                blocks.append(.object([
                    "type": .string("tool_use"),
                    "id": .string(normalizeToolCallId(call.id)),
                    "name": .string(call.name),
                    "input": call.arguments.objectValue.map { JSONValue.object($0) } ?? .object([:]),
                ]))

            case .image:
                continue
            }
        }
        guard !blocks.isEmpty else { return nil }
        return .object([
            "role": .string("assistant"),
            "content": .array(blocks),
        ])
    }

    private static func convertToolResult(_ result: ToolResultMessage) -> JSONValue {
        // Anthropic rejects non-text error results, so images are replaced.
        let blocks: [ContentBlock]
        if result.isError {
            blocks = result.content.map { block in
                if case .image = block {
                    return .text(TextContent(text: "[image omitted: error tool results cannot contain images]"))
                }
                return block
            }
        } else {
            blocks = result.content
        }

        var object: JSONObject = [
            "type": .string("tool_result"),
            "tool_use_id": .string(normalizeToolCallId(result.toolCallId)),
            "content": convertContentBlocks(blocks),
        ]
        if result.isError { object["is_error"] = .bool(true) }
        return .object(object)
    }

    /// Mirrors upstream `convertContentBlocks`: text-only content collapses to a
    /// string, content with images becomes a block array (with a placeholder
    /// added when there is no text).
    static func convertContentBlocks(_ blocks: [ContentBlock]) -> JSONValue {
        let hasImages = blocks.contains { block in
            if case .image = block { return true }
            return false
        }

        if !hasImages {
            let text = blocks.compactMap { block -> String? in
                guard case .text(let content) = block else { return nil }
                return SanitizeUnicode.sanitize(content.text)
            }.joined(separator: "\n")
            return .string(text)
        }

        var parts: [JSONValue] = []
        for block in blocks {
            switch block {
            case .text(let content):
                parts.append(textBlock(content.text))
            case .image(let image):
                parts.append(imageBlock(image))
            case .thinking, .toolCall:
                continue
            }
        }
        let hasText = parts.contains { $0["type"].stringValue == "text" }
        if !hasText {
            parts.insert(textBlock("(see attached image)"), at: 0)
        }
        return .array(parts)
    }

    private static func imageBlock(_ image: ImageContent) -> JSONValue {
        .object([
            "type": .string("image"),
            "source": .object([
                "type": .string("base64"),
                "media_type": .string(image.mimeType),
                "data": .string(image.data),
            ]),
        ])
    }

    // MARK: - Tools

    /// Converts a tool declaration to `{ name, description, input_schema }`.
    static func convertTool(_ tool: Tool) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "input_schema": tool.parameters.makeJSONValue(),
        ])
    }

    // MARK: - Helpers

    /// Normalizes a tool-call id to Anthropic's `[a-zA-Z0-9_-]` pattern and
    /// 64-character limit (upstream `normalizeToolCallId`).
    static func normalizeToolCallId(_ id: String) -> String {
        var result = String()
        for scalar in id.unicodeScalars {
            if result.unicodeScalars.count >= 64 { break }
            let value = scalar.value
            let allowed = (value >= 0x41 && value <= 0x5A)
                || (value >= 0x61 && value <= 0x7A)
                || (value >= 0x30 && value <= 0x39)
                || scalar == "_"
                || scalar == "-"
            result.unicodeScalars.append(allowed ? scalar : "_")
        }
        return result
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
}
