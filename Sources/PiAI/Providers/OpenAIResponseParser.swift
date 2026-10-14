import Foundation

/// Errors produced while parsing a non-streaming Chat Completions response.
public enum OpenAIResponseError: Error, Sendable, Equatable, LocalizedError {
    case emptyChoices
    case malformedMessage
    case invalidToolArguments(String)

    public var errorDescription: String? {
        switch self {
        case .emptyChoices:
            return "Response contained no choices"
        case .malformedMessage:
            return "Response choice did not contain a message object"
        case .invalidToolArguments(let arguments):
            return "Invalid tool call arguments: \(arguments)"
        }
    }
}

/// Parses a full (non-streaming) OpenAI Chat Completions response.
///
/// Upstream has no non-streaming path; this is a Swift-specific derivation that
/// consumes the same JSON shape with `stream: false`. It reuses the streaming
/// parse rules for content, reasoning, tool calls, usage and `finish_reason`.
public enum OpenAIResponseParser {
    public static func parse(_ data: Data, model: Model) throws -> AssistantMessage {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw OpenAIResponseError.malformedMessage
        }
        return try parse(value, model: model)
    }

    public static func parse(_ value: JSONValue, model: Model) throws -> AssistantMessage {
        guard let object = value.objectValue else {
            throw OpenAIResponseError.malformedMessage
        }
        guard let choices = object["choices"]?.arrayValue, !choices.isEmpty else {
            throw OpenAIResponseError.emptyChoices
        }
        guard let choice = choices[0].objectValue,
              let message = choice["message"]?.objectValue else {
            throw OpenAIResponseError.malformedMessage
        }

        var content: [ContentBlock] = []

        // Reasoning precedes answer content, matching the streaming block order.
        let reasoningFields = ["reasoning_content", "reasoning", "reasoning_text"]
        for field in reasoningFields {
            if let reasoning = message[field]?.stringValue, !reasoning.isEmpty {
                content.append(.thinking(ThinkingContent(thinking: reasoning, thinkingSignature: field)))
                break
            }
        }

        if let text = message["content"]?.stringValue, !text.isEmpty {
            content.append(.text(TextContent(text: text)))
        }

        if let toolCalls = message["tool_calls"]?.arrayValue {
            for toolCall in toolCalls {
                guard let call = toolCall.objectValue else { continue }
                let function = call["function"]?.objectValue
                let id = call["id"]?.stringValue ?? ""
                let name = function?["name"]?.stringValue ?? ""
                let arguments = parseToolArguments(function?["arguments"]?.stringValue)
                content.append(.toolCall(ToolCall(id: id, name: name, arguments: arguments)))
            }
        }

        let finishReason = choice["finish_reason"]?.stringValue
        let mapped = mapStopReason(finishReason)
        let usage = parseUsage(object["usage"] ?? .null)

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
            stopReason: mapped.stopReason,
            errorMessage: mapped.errorMessage,
            rawStopReason: finishReason,
            timestamp: Self.nowMillis()
        )
    }

    // MARK: - Stop reason

    static func mapStopReason(_ reason: String?) -> (stopReason: StopReason, errorMessage: String?) {
        guard let reason else { return (.stop, nil) }
        switch reason {
        case "stop", "end":
            return (.stop, nil)
        case "length":
            return (.length, nil)
        case "function_call", "tool_calls":
            return (.toolUse, nil)
        case "content_filter":
            return (.error, "Provider finish_reason: content_filter")
        case "network_error":
            return (.error, "Provider finish_reason: network_error")
        default:
            return (.error, "Provider finish_reason: \(reason)")
        }
    }

    // MARK: - Usage

    static func parseUsage(_ value: JSONValue) -> Usage {
        let usage = value.objectValue ?? [:]
        let promptTokens = usage["prompt_tokens"]?.intValue ?? 0
        let promptDetails = usage["prompt_tokens_details"]?.objectValue
        let cacheRead = promptDetails?["cached_tokens"]?.intValue
            ?? usage["prompt_cache_hit_tokens"]?.intValue
            ?? usage["cached_tokens"]?.intValue
            ?? 0
        let cacheWrite = promptDetails?["cache_write_tokens"]?.intValue ?? 0
        let input = max(0, promptTokens - cacheRead - cacheWrite)
        let output = usage["completion_tokens"]?.intValue ?? 0
        let completionDetails = usage["completion_tokens_details"]?.objectValue
        let reasoning = completionDetails?["reasoning_tokens"]?.intValue ?? 0

        return Usage(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            reasoning: reasoning,
            totalTokens: input + output + cacheRead + cacheWrite,
            cost: .zero
        )
    }

    // MARK: - Tool arguments

    /// Parses a tool-call `arguments` JSON string. Empty or malformed input
    /// returns `{}` (best effort) rather than throwing; ``OpenAIResponseError``
    /// exposes ``OpenAIResponseError/invalidToolArguments(_:)`` for callers that
    /// need the distinction but the parser intentionally does not throw it.
    static func parseToolArguments(_ raw: String?) -> JSONValue {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .object([:])
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) else {
            return .object([:])
        }
        return value
    }

    static func nowMillis() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}
