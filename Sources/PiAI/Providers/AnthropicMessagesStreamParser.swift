import Foundation

/// Errors surfaced by the streaming Anthropic Messages provider.
public enum AnthropicMessagesStreamError: Error, Sendable, Equatable, LocalizedError {
    /// The transport finished before a `message_stop` event.
    case missingTerminalEvent
    /// The transport finished without a stop reason (`message_delta`).
    case missingStopReason
    /// The provider reported an `error` event.
    case providerError(String)

    public var errorDescription: String? {
        switch self {
        case .missingTerminalEvent:
            return "Anthropic Messages stream ended before message_stop"
        case .missingStopReason:
            return "Anthropic Messages stream ended without a stop reason"
        case .providerError(let message):
            return message
        }
    }
}

/// Shared field mapping for streaming and non-streaming Messages payloads.
enum AnthropicMessagesMapping {
    /// Maps an Anthropic `stop_reason` to a pi ``StopReason``.
    static func mapStopReason(_ reason: String?) -> (stopReason: StopReason, errorMessage: String?) {
        guard let reason else { return (.stop, nil) }
        switch reason {
        case "end_turn", "stop_sequence", "pause_turn":
            return (.stop, nil)
        case "max_tokens":
            return (.length, nil)
        case "tool_use":
            return (.toolUse, nil)
        case "refusal":
            return (.error, "The model refused to complete the request")
        case "sensitive":
            return (.error, "Provider stopped with: sensitive")
        default:
            return (.error, "Unhandled stop reason: \(reason)")
        }
    }

    /// Parses an Anthropic `usage` object. Anthropic does not report a request
    /// total, so it is computed from the components.
    static func parseUsage(_ value: JSONValue) -> Usage {
        let input = value["input_tokens"].intValue ?? 0
        let output = value["output_tokens"].intValue ?? 0
        let cacheRead = value["cache_read_input_tokens"].intValue ?? 0
        let cacheWrite = value["cache_creation_input_tokens"].intValue ?? 0
        let cacheWrite1h = value["cache_creation"]["ephemeral_1h_input_tokens"].intValue
        let reasoning = value["output_tokens_details"]["thinking_tokens"].intValue
        return Usage(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            cacheWrite1h: cacheWrite1h,
            reasoning: reasoning,
            totalTokens: input + output + cacheRead + cacheWrite,
            cost: .zero
        )
    }
}

/// Incremental parser for Anthropic Messages server-sent events.
///
/// Folds `message_*` / `content_block_*` events into content blocks and emits
/// the simplified ``AssistantMessageEvent`` deltas, mirroring the streaming
/// subset of upstream `api/anthropic-messages.ts`.
struct AnthropicMessagesStreamParser {
    private let model: Model
    private let timestamp: Int

    private struct ToolState {
        var contentIndex: Int
        var toolIndex: Int
        var id: String
        var name: String
        var initialInput: JSONValue
        var partialJSON: String = ""
    }

    private var content: [ContentBlock] = []
    private var indexToContent: [Int: Int] = [:]
    private var toolStates: [Int: ToolState] = [:]
    private var toolCallCount = 0

    private(set) var responseId: String?
    private(set) var responseModel: String?
    private(set) var usage: Usage = .zero
    private(set) var stopReason: StopReason = .pending
    private(set) var rawStopReason: String?
    private(set) var errorMessage: String?
    private(set) var sawMessageStart = false
    private(set) var sawMessageStop = false

    init(model: Model, timestamp: Int) {
        self.model = model
        self.timestamp = timestamp
    }

    /// Folds one decoded SSE payload into the accumulator and returns the
    /// deltas it produced. Throws for provider `error` events.
    mutating func consume(_ value: JSONValue) throws -> [AssistantMessageEvent] {
        guard let object = value.objectValue, let type = object["type"]?.stringValue else { return [] }
        var events: [AssistantMessageEvent] = []

        switch type {
        case "message_start":
            sawMessageStart = true
            let message = object["message"] ?? .null
            if let id = message["id"].stringValue, !id.isEmpty {
                responseId = id
            }
            if let modelId = message["model"].stringValue, !modelId.isEmpty, modelId != model.id {
                responseModel = modelId
            }
            usage = AnthropicMessagesMapping.parseUsage(message["usage"])

        case "content_block_start":
            guard let index = object["index"]?.intValue,
                  let block = object["content_block"]?.objectValue else { break }
            createBlock(index: index, block: block)

        case "content_block_delta":
            guard let index = object["index"]?.intValue,
                  let delta = object["delta"]?.objectValue,
                  let contentIndex = indexToContent[index] else { break }
            switch delta["type"]?.stringValue {
            case "text_delta":
                guard let text = delta["text"]?.stringValue, !text.isEmpty else { break }
                appendText(at: contentIndex, text)
                events.append(.textDelta(text))

            case "thinking_delta":
                guard let thinking = delta["thinking"]?.stringValue, !thinking.isEmpty else { break }
                appendThinking(at: contentIndex, thinking)
                events.append(.thinkingDelta(thinking))

            case "signature_delta":
                guard let signature = delta["signature"]?.stringValue, !signature.isEmpty else { break }
                appendSignature(at: contentIndex, signature)

            case "input_json_delta":
                guard var state = toolStates[index],
                      let fragment = delta["partial_json"]?.stringValue, !fragment.isEmpty else { break }
                state.partialJSON += fragment
                toolStates[index] = state
                events.append(.toolCallDelta(
                    index: state.toolIndex,
                    id: state.id,
                    name: state.name,
                    argumentsFragment: fragment
                ))

            default:
                break
            }

        case "content_block_stop":
            guard let index = object["index"]?.intValue else { break }
            finalizeToolCall(index: index)

        case "message_delta":
            let delta = object["delta"] ?? .null
            if let reason = delta["stop_reason"].stringValue {
                rawStopReason = reason
                let mapped = AnthropicMessagesMapping.mapStopReason(reason)
                stopReason = mapped.stopReason
                errorMessage = mapped.errorMessage
            }
            applyDeltaUsage(object["usage"] ?? .null)

        case "message_stop":
            sawMessageStop = true

        case "error":
            throw AnthropicMessagesStreamError.providerError(Self.errorMessage(from: object))

        default:
            // `ping` and future events are ignored.
            break
        }

        return events
    }

    /// Builds the final assistant message from the accumulated state.
    func finalize() -> AssistantMessage {
        AssistantMessage(
            content: content,
            api: model.api,
            provider: model.provider,
            model: model.id,
            responseModel: responseModel,
            responseId: responseId,
            usage: usage,
            stopReason: stopReason,
            errorMessage: errorMessage,
            rawStopReason: rawStopReason,
            timestamp: timestamp
        )
    }

    // MARK: - Blocks

    private mutating func createBlock(index: Int, block: JSONObject) {
        switch block["type"]?.stringValue {
        case "text":
            content.append(.text(TextContent(text: block["text"]?.stringValue ?? "")))
            indexToContent[index] = content.count - 1

        case "thinking":
            content.append(.thinking(ThinkingContent(
                thinking: block["thinking"]?.stringValue ?? "",
                thinkingSignature: block["signature"]?.stringValue
            )))
            indexToContent[index] = content.count - 1

        case "redacted_thinking":
            content.append(.thinking(ThinkingContent(
                thinking: "[Reasoning redacted]",
                thinkingSignature: block["data"]?.stringValue,
                redacted: true
            )))
            indexToContent[index] = content.count - 1

        case "tool_use":
            let id = block["id"]?.stringValue ?? ""
            let name = block["name"]?.stringValue ?? ""
            let input = block["input"] ?? .object([:])
            content.append(.toolCall(ToolCall(id: id, name: name, arguments: input)))
            let contentIndex = content.count - 1
            indexToContent[index] = contentIndex
            toolStates[index] = ToolState(
                contentIndex: contentIndex,
                toolIndex: toolCallCount,
                id: id,
                name: name,
                initialInput: input
            )
            toolCallCount += 1

        default:
            break
        }
    }

    private mutating func finalizeToolCall(index: Int) {
        guard var state = toolStates[index] else { return }
        if !state.partialJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = JSONParse.parse(state.partialJSON) ?? state.initialInput
            if case .toolCall(var call) = content[state.contentIndex] {
                call.arguments = parsed
                content[state.contentIndex] = .toolCall(call)
            }
        }
        state.partialJSON = ""
        toolStates.removeValue(forKey: index)
    }

    private mutating func appendText(at index: Int, _ delta: String) {
        guard case .text(var block) = content[index] else { return }
        block.text += delta
        content[index] = .text(block)
    }

    private mutating func appendThinking(at index: Int, _ delta: String) {
        guard case .thinking(var block) = content[index] else { return }
        block.thinking += delta
        content[index] = .thinking(block)
    }

    private mutating func appendSignature(at index: Int, _ signature: String) {
        guard case .thinking(var block) = content[index] else { return }
        block.thinkingSignature = (block.thinkingSignature ?? "") + signature
        content[index] = .thinking(block)
    }

    // MARK: - Usage

    private mutating func applyDeltaUsage(_ value: JSONValue) {
        if let tokens = value["input_tokens"].intValue { usage.input = tokens }
        if let tokens = value["output_tokens"].intValue { usage.output = tokens }
        if let tokens = value["cache_read_input_tokens"].intValue { usage.cacheRead = tokens }
        if let tokens = value["cache_creation_input_tokens"].intValue { usage.cacheWrite = tokens }
        if let tokens = value["cache_creation"]["ephemeral_1h_input_tokens"].intValue {
            usage.cacheWrite1h = tokens
        }
        if let tokens = value["output_tokens_details"]["thinking_tokens"].intValue {
            usage.reasoning = tokens
        }
        usage.totalTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite
    }

    // MARK: - Error events

    private static func errorMessage(from object: JSONObject) -> String {
        let error = object["error"]?.objectValue
        let type = error?["type"]?.stringValue ?? "error"
        let message = error?["message"]?.stringValue ?? "Unknown error"
        return "\(type): \(message)"
    }
}
