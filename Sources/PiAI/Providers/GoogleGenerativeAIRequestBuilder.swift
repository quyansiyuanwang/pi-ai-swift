import Foundation

/// Errors produced while building a Google Generative AI request.
public enum GoogleGenerativeAIRequestError: Error, Sendable, Equatable, LocalizedError {
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

/// Builds Google Generative AI (`google-generative-ai`) requests.
///
/// Swift port of the request-shaping subset of upstream
/// `api/google-generative-ai.ts` (`buildParams` + `api/google-shared.ts`
/// `convertMessages` / `convertTools`). Vertex AI, OAuth, prompt caching,
/// safety-setting overrides, thinking-level (Gemini 3) control and media
/// generation are intentionally out of scope; thinking is requested with a
/// token budget only.
public enum GoogleGenerativeAIRequestBuilder {
    /// Builds a `POST .../models/{model}:generateContent` (or
    /// `:streamGenerateContent?alt=sse`) request.
    public static func makeRequest(
        model: Model,
        context: ChatContext,
        options: ChatOptions,
        streaming: Bool = false,
        thinkingBudget: Int? = nil
    ) throws -> URLRequest {
        let url = try resolveURL(baseURL: model.baseURL, model: model.id, streaming: streaming)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": streaming ? "text/event-stream" : "application/json",
            "User-Agent": PiUserAgent.current,
        ]
        for (name, value) in model.headers {
            setHeader(&headers, name: name, value: value)
        }
        for (name, value) in options.headers {
            setHeader(&headers, name: name, value: value)
        }

        if !options.apiKey.isEmpty {
            setHeader(&headers, name: "x-goog-api-key", value: options.apiKey)
        } else if !hasHeader(headers, "x-goog-api-key") {
            throw GoogleGenerativeAIRequestError.missingAPIKey(provider: model.provider)
        }

        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(
            makeBody(model: model, context: context, options: options, thinkingBudget: thinkingBudget)
        )
        return request
    }

    /// Builds the JSON request body.
    public static func makeBody(
        model: Model,
        context: ChatContext,
        options: ChatOptions,
        thinkingBudget: Int? = nil
    ) -> JSONValue {
        var body: JSONObject = [
            "contents": .array(convertMessages(model: model, context: context)),
        ]

        if let systemInstruction = convertSystemInstruction(context: context) {
            body["systemInstruction"] = systemInstruction
        }
        if let tools = convertTools(context.tools) {
            body["tools"] = tools
        }

        var generationConfig: JSONObject = [:]
        if let temperature = options.temperature {
            generationConfig["temperature"] = .number(temperature)
        }
        if let topP = options.topP {
            generationConfig["topP"] = .number(topP)
        }
        if let maxTokens = options.maxTokens {
            generationConfig["maxOutputTokens"] = .int(maxTokens)
        }
        if let thinkingBudget {
            generationConfig["thinkingConfig"] = .object(["thinkingBudget": .int(thinkingBudget)])
        }
        if !generationConfig.isEmpty {
            body["generationConfig"] = .object(generationConfig)
        }

        return .object(body)
    }

    // MARK: - URL

    /// Joins `baseURL` with the model method path, appending `/v1beta` only when
    /// the base URL does not already carry a `/v1` or `/v1beta` version segment.
    static func resolveURL(baseURL: String, model: String, streaming: Bool) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }

        guard !base.isEmpty,
              var components = URLComponents(string: base),
              components.scheme != nil,
              components.host != nil else {
            throw GoogleGenerativeAIRequestError.invalidBaseURL(baseURL)
        }

        let hasVersion = components.path.hasSuffix("/v1beta") || components.path.hasSuffix("/v1")
        let versionPath = hasVersion ? "" : "/v1beta"
        let method = streaming ? "streamGenerateContent" : "generateContent"
        components.path += "\(versionPath)/models/\(model):\(method)"

        if streaming {
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "alt", value: "sse"))
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw GoogleGenerativeAIRequestError.invalidBaseURL(baseURL)
        }
        return url
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

    // MARK: - System instruction

    /// Builds the top-level `systemInstruction` block from the context system
    /// prompt and any `system` messages.
    static func convertSystemInstruction(context: ChatContext) -> JSONValue? {
        var texts: [String] = []
        if let systemPrompt = context.systemPrompt, !systemPrompt.isEmpty {
            texts.append(systemPrompt)
        }
        for message in context.messages {
            guard case .system(let system) = message else { continue }
            let text = text(of: system.content)
            if !text.isEmpty { texts.append(text) }
        }
        guard !texts.isEmpty else { return nil }
        let joined = SanitizeUnicode.sanitize(texts.joined(separator: "\n\n"))
        return .object([
            "parts": .array([.object(["text": .string(joined)])]),
        ])
    }

    // MARK: - Messages

    /// Converts the transcript into Gemini `contents`, dropping `system`
    /// messages (sent as `systemInstruction`) and grouping consecutive tool
    /// results into one user turn.
    static func convertMessages(model: Model, context: ChatContext) -> [JSONValue] {
        var contents: [JSONValue] = []
        let source = context.messages
        var index = 0

        while index < source.count {
            switch source[index] {
            case .system:
                index += 1

            case .user(let user):
                if let value = convertUser(user) { contents.append(value) }
                index += 1

            case .assistant(let assistant):
                if let value = convertAssistant(model: model, assistant) { contents.append(value) }
                index += 1

            case .toolResult:
                var parts: [JSONValue] = []
                while index < source.count, case .toolResult(let result) = source[index] {
                    parts.append(convertToolResult(model: model, result))
                    index += 1
                }
                if !parts.isEmpty {
                    contents.append(.object([
                        "role": .string("user"),
                        "parts": .array(parts),
                    ]))
                }
            }
        }

        return contents
    }

    private static func convertUser(_ user: UserMessage) -> JSONValue? {
        switch user.content {
        case .text(let string):
            return .object([
                "role": .string("user"),
                "parts": .array([
                    .object(["text": .string(SanitizeUnicode.sanitize(string))]),
                ]),
            ])

        case .blocks(let blocks):
            var parts: [JSONValue] = []
            for block in blocks {
                switch block {
                case .text(let content):
                    parts.append(.object(["text": .string(SanitizeUnicode.sanitize(content.text))]))
                case .image(let image):
                    parts.append(inlineData(image))
                case .thinking, .toolCall:
                    continue
                }
            }
            guard !parts.isEmpty else { return nil }
            return .object([
                "role": .string("user"),
                "parts": .array(parts),
            ])
        }
    }

    private static func convertAssistant(model: Model, _ assistant: AssistantMessage) -> JSONValue? {
        let sameProviderAndModel = assistant.provider == model.provider && assistant.model == model.id
        var parts: [JSONValue] = []

        for block in assistant.content {
            switch block {
            case .text(let content):
                let signature = sameProviderAndModel
                    ? validSignature(content.textSignature)
                    : nil
                let text = SanitizeUnicode.sanitize(content.text)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && signature == nil {
                    continue
                }
                var part: JSONObject = ["text": .string(text)]
                if let signature { part["thoughtSignature"] = .string(signature) }
                parts.append(.object(part))

            case .thinking(let content):
                let signature = sameProviderAndModel
                    ? validSignature(content.thinkingSignature)
                    : nil
                let thinking = SanitizeUnicode.sanitize(content.thinking)
                if sameProviderAndModel {
                    if thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && signature == nil {
                        continue
                    }
                    var part: JSONObject = [
                        "thought": .bool(true),
                        "text": .string(thinking),
                    ]
                    if let signature { part["thoughtSignature"] = .string(signature) }
                    parts.append(.object(part))
                } else {
                    // The signature is unusable across providers/models; replay
                    // the reasoning as plain text (upstream behavior).
                    if thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    parts.append(.object(["text": .string(thinking)]))
                }

            case .toolCall(let call):
                let signature = sameProviderAndModel ? validSignature(call.thoughtSignature) : nil
                var part: JSONObject = [
                    "functionCall": .object([
                        "name": .string(call.name),
                        "args": call.arguments.objectValue.map { JSONValue.object($0) } ?? .object([:]),
                    ]),
                ]
                if let signature { part["thoughtSignature"] = .string(signature) }
                parts.append(.object(part))

            case .image:
                continue
            }
        }

        guard !parts.isEmpty else { return nil }
        return .object([
            "role": .string("model"),
            "parts": .array(parts),
        ])
    }

    private static func convertToolResult(model: Model, _ result: ToolResultMessage) -> JSONValue {
        let text = result.content.compactMap { block -> String? in
            guard case .text(let content) = block else { return nil }
            return content.text
        }.joined(separator: "\n")
        let images = model.input.contains(.image)
            ? result.content.compactMap { block -> ImageContent? in
                guard case .image(let image) = block else { return nil }
                return image
            }
            : []

        let responseKey = result.isError ? "error" : "output"
        let responseValue = text.isEmpty
            ? (images.isEmpty ? "" : "(see attached image)")
            : SanitizeUnicode.sanitize(text)

        var functionResponse: JSONObject = [
            "name": .string(result.toolName),
            "response": .object([responseKey: .string(responseValue)]),
        ]
        // Gemini 3+ (and non-Gemini models behind the same API surface) accept
        // images nested inside `functionResponse.parts`.
        if !images.isEmpty, supportsMultimodalFunctionResponse(model.id) {
            functionResponse["parts"] = .array(images.map(inlineData))
        }

        return .object(["functionResponse": .object(functionResponse)])
    }

    // MARK: - Tools

    /// Converts tool declarations to `{ functionDeclarations: [...] }`.
    static func convertTools(_ tools: [Tool]) -> JSONValue? {
        guard !tools.isEmpty else { return nil }
        let declarations = tools.map { tool -> JSONValue in
            .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": sanitizeForOpenAPI(tool.parameters.makeJSONValue()),
            ])
        }
        return .array([
            .object(["functionDeclarations": .array(declarations)]),
        ])
    }

    private static let jsonSchemaMetaDeclarations: Set<String> = [
        "$schema", "$id", "$anchor", "$dynamicAnchor", "$vocabulary", "$comment", "$defs", "definitions",
    ]

    /// Strips JSON Schema meta-declarations unsupported by the OpenAPI 3.0
    /// schema dialect used by Gemini's `parameters` field.
    static func sanitizeForOpenAPI(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var result: JSONObject = [:]
            for (key, nested) in object where !jsonSchemaMetaDeclarations.contains(key) {
                result[key] = sanitizeForOpenAPI(nested)
            }
            return .object(result)
        case .array(let array):
            return .array(array.map(sanitizeForOpenAPI))
        default:
            return value
        }
    }

    // MARK: - Helpers

    private static func inlineData(_ image: ImageContent) -> JSONValue {
        .object([
            "inlineData": .object([
                "mimeType": .string(image.mimeType),
                "data": .string(image.data),
            ]),
        ])
    }

    private static func validSignature(_ signature: String?) -> String? {
        GoogleGenerativeAIMapping.isValidThoughtSignature(signature) ? signature : nil
    }

    /// Whether Gemini accepts images nested inside `functionResponse.parts`
    /// (Gemini 3+; non-Gemini model ids default to supported).
    private static func supportsMultimodalFunctionResponse(_ modelID: String) -> Bool {
        guard let major = geminiMajorVersion(modelID) else { return true }
        return major >= 3
    }

    private static func geminiMajorVersion(_ modelID: String) -> Int? {
        let lowered = modelID.lowercased()
        guard lowered.hasPrefix("gemini") else { return nil }
        guard let range = lowered.range(of: #"^gemini(?:-live)?-(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let digits = lowered[range].filter(\.isNumber)
        return Int(digits)
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
