import Foundation

/// Errors surfaced while parsing a Responses API payload.
public enum OpenAIResponsesResponseError: Error, Sendable, Equatable, LocalizedError {
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .malformedResponse:
            return "Response payload is not a JSON object"
        }
    }
}

/// Shared field mapping for streaming and non-streaming Responses payloads.
enum OpenAIResponsesMapping {
    /// Maps a Responses `status` (plus optional `incomplete_details.reason`)
    /// to a pi ``StopReason``.
    static func mapStopReason(
        status: String?,
        incompleteReason: String?
    ) -> (stopReason: StopReason, errorMessage: String?) {
        guard let status else { return (.stop, nil) }
        switch status {
        case "completed":
            return (.stop, nil)
        case "incomplete":
            if incompleteReason == "max_output_tokens" {
                return (.length, nil)
            }
            return (
                .error,
                incompleteReason.map { "Response incomplete: \($0)" }
                    ?? "Response incomplete without a provider reason"
            )
        case "failed", "cancelled":
            return (.error, nil)
        // These two are still in flight upstream but treated as clean stops.
        case "in_progress", "queued":
            return (.stop, nil)
        default:
            return (.stop, nil)
        }
    }

    /// Parses a Responses `usage` object. `input_tokens` includes cached and
    /// cache-write tokens, so those are subtracted from ``Usage/input``.
    static func parseUsage(_ value: JSONValue) -> Usage {
        let usage = value.objectValue ?? [:]
        let inputTokens = usage["input_tokens"]?.intValue ?? 0
        let inputDetails = usage["input_tokens_details"]?.objectValue
        let cacheRead = inputDetails?["cached_tokens"]?.intValue ?? 0
        let cacheWrite = inputDetails?["cache_write_tokens"]?.intValue ?? 0
        let input = max(0, inputTokens - cacheRead - cacheWrite)
        let output = usage["output_tokens"]?.intValue ?? 0
        let reasoningDetails = usage["output_tokens_details"] ?? .null
        let reasoning = reasoningDetails["reasoning_tokens"].intValue ?? 0
        let total = usage["total_tokens"]?.intValue ?? (input + output + cacheRead + cacheWrite)
        return Usage(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            reasoning: reasoning,
            totalTokens: total,
            cost: .zero
        )
    }

    /// Joins the `text` field of an array of items (reasoning summary/content).
    static func joinedText(_ value: JSONValue?) -> String {
        guard let array = value?.arrayValue else { return "" }
        return array.compactMap { $0["text"].stringValue }.joined(separator: "\n\n")
    }

    /// Joins the text/refusal parts of a message item's `content` array.
    static func joinedContent(_ value: JSONValue?) -> String {
        guard let array = value?.arrayValue else { return "" }
        return array.compactMap { part -> String? in
            guard let object = part.objectValue else { return nil }
            switch object["type"]?.stringValue {
            case "output_text": return object["text"]?.stringValue
            case "refusal": return object["refusal"]?.stringValue
            default: return nil
            }
        }.joined()
    }

    /// Builds content blocks from a full Responses `output` array.
    static func content(from output: JSONValue) -> [ContentBlock] {
        var content: [ContentBlock] = []
        for itemValue in output.arrayValue ?? [] {
            guard let item = itemValue.objectValue else { continue }
            switch item["type"]?.stringValue {
            case "reasoning":
                let summary = joinedText(item["summary"])
                let reasoning = joinedText(item["content"])
                let thinking = summary.isEmpty ? reasoning : summary
                if !thinking.isEmpty {
                    content.append(.thinking(ThinkingContent(thinking: thinking)))
                }
            case "message":
                let text = joinedContent(item["content"])
                if !text.isEmpty {
                    content.append(.text(TextContent(text: text)))
                }
            case "function_call":
                let callId = item["call_id"]?.stringValue ?? item["id"]?.stringValue ?? ""
                let name = item["name"]?.stringValue ?? ""
                let arguments = JSONParse.parse(item["arguments"]?.stringValue ?? "") ?? .object([:])
                content.append(.toolCall(ToolCall(id: callId, name: name, arguments: arguments)))
            default:
                continue
            }
        }
        return content
    }
}

/// Parses a full (non-streaming) OpenAI Responses response.
///
/// Upstream is streaming-only; this is a Swift-specific derivation that consumes
/// the same `response` object shape with `stream: false`.
public enum OpenAIResponsesResponseParser {
    public static func parse(_ data: Data, model: Model) throws -> AssistantMessage {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw OpenAIResponsesResponseError.malformedResponse
        }
        return try parse(value, model: model)
    }

    public static func parse(_ value: JSONValue, model: Model) throws -> AssistantMessage {
        guard var object = value.objectValue else {
            throw OpenAIResponsesResponseError.malformedResponse
        }
        // Tolerate an SDK-style envelope that wraps the response object.
        if object["output"] == nil, let nested = object["response"]?.objectValue {
            object = nested
        }

        let content = OpenAIResponsesMapping.content(from: object["output"] ?? .array([]))
        let status = object["status"]?.stringValue
        let incomplete = object["incomplete_details"] ?? .null
        let incompleteReason = incomplete["reason"].stringValue
        let mapped = OpenAIResponsesMapping.mapStopReason(status: status, incompleteReason: incompleteReason)

        var stopReason = mapped.stopReason
        if stopReason == .stop, content.contains(where: { block in
            if case .toolCall = block { return true }
            return false
        }) {
            stopReason = .toolUse
        }

        let usage = object["usage"].map(OpenAIResponsesMapping.parseUsage) ?? .zero
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
            rawStopReason: incompleteReason.map { "\(status ?? "").\($0)" } ?? status,
            timestamp: OpenAIResponseParser.nowMillis()
        )
    }
}
