import Foundation

/// Errors surfaced while parsing a non-streaming Anthropic Messages payload.
public enum AnthropicMessagesResponseError: Error, Sendable, Equatable, LocalizedError {
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .malformedResponse:
            return "Messages payload is not a JSON object"
        }
    }
}

/// Parses a full (non-streaming) Anthropic Messages response.
///
/// Upstream is streaming-only; this is a Swift-specific derivation that consumes
/// the same `message` object shape with `stream: false`.
public enum AnthropicMessagesResponseParser {
    public static func parse(_ data: Data, model: Model) throws -> AssistantMessage {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw AnthropicMessagesResponseError.malformedResponse
        }
        return try parse(value, model: model)
    }

    public static func parse(_ value: JSONValue, model: Model) throws -> AssistantMessage {
        guard var object = value.objectValue else {
            throw AnthropicMessagesResponseError.malformedResponse
        }
        // Tolerate an envelope that wraps the message object.
        if object["content"] == nil, let nested = object["message"]?.objectValue {
            object = nested
        }

        var content: [ContentBlock] = []
        for blockValue in object["content"]?.arrayValue ?? [] {
            guard let block = blockValue.objectValue else { continue }
            switch block["type"]?.stringValue {
            case "text":
                let text = block["text"]?.stringValue ?? ""
                if !text.isEmpty {
                    content.append(.text(TextContent(text: text)))
                }
            case "thinking":
                content.append(.thinking(ThinkingContent(
                    thinking: block["thinking"]?.stringValue ?? "",
                    thinkingSignature: block["signature"]?.stringValue
                )))
            case "redacted_thinking":
                content.append(.thinking(ThinkingContent(
                    thinking: "[Reasoning redacted]",
                    thinkingSignature: block["data"]?.stringValue,
                    redacted: true
                )))
            case "tool_use":
                let id = block["id"]?.stringValue ?? ""
                let name = block["name"]?.stringValue ?? ""
                content.append(.toolCall(ToolCall(
                    id: id,
                    name: name,
                    arguments: block["input"] ?? .object([:])
                )))
            default:
                continue
            }
        }

        let rawStopReason = object["stop_reason"]?.stringValue
        let mapped = AnthropicMessagesMapping.mapStopReason(rawStopReason)
        var stopReason = mapped.stopReason
        if stopReason == .stop, content.contains(where: { block in
            if case .toolCall = block { return true }
            return false
        }) {
            stopReason = .toolUse
        }

        let usage = AnthropicMessagesMapping.parseUsage(object["usage"] ?? .null)
        let responseModel = object["model"]?.stringValue.flatMap { candidate -> String? in
            guard !candidate.isEmpty, candidate != model.id else { return nil }
            return candidate
        }

        return AssistantMessage(
            content: content,
            api: model.api,
            provider: model.provider,
            model: model.id,
            responseModel: responseModel,
            responseId: object["id"]?.stringValue,
            usage: usage,
            stopReason: stopReason,
            errorMessage: mapped.errorMessage,
            rawStopReason: rawStopReason,
            timestamp: OpenAIResponseParser.nowMillis()
        )
    }
}
