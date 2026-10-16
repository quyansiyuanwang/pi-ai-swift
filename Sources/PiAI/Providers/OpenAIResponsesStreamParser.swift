import Foundation

/// Errors surfaced by the streaming OpenAI Responses provider.
public enum OpenAIResponsesStreamError: Error, Sendable, Equatable, LocalizedError {
    /// The transport finished without a terminal response event.
    case missingTerminalEvent
    /// The provider reported an error event (`error` / `response.failed`).
    case providerError(String)
    /// A tool call was never finalized by `response.output_item.done`.
    case unfinishedToolCall(String)

    public var errorDescription: String? {
        switch self {
        case .missingTerminalEvent:
            return "OpenAI Responses stream ended before a terminal response event"
        case .providerError(let message):
            return message
        case .unfinishedToolCall(let name):
            return "OpenAI Responses stream completed with an unfinished tool call: \(name)"
        }
    }
}

/// Incremental parser for OpenAI Responses server-sent events.
///
/// Folds `response.*` events into content blocks and emits the simplified
/// ``AssistantMessageEvent`` deltas, mirroring the streaming subset of upstream
/// `processResponsesStream`.
struct OpenAIResponsesStreamParser {
    private let model: Model
    private let timestamp: Int

    private enum Slot {
        case thinking(contentIndex: Int)
        case text(contentIndex: Int)
        case toolCall(contentIndex: Int, toolIndex: Int, callId: String, name: String)
    }

    private var content: [ContentBlock] = []
    private var slots: [Int: Slot] = [:]
    private var partialArguments: [Int: String] = [:]
    private var toolCallCount = 0

    private(set) var responseId: String?
    private(set) var usage: Usage = .zero
    private(set) var stopReason: StopReason = .pending
    private(set) var rawStopReason: String?
    private(set) var errorMessage: String?
    private(set) var sawTerminalEvent = false

    init(model: Model, timestamp: Int) {
        self.model = model
        self.timestamp = timestamp
    }

    /// Folds one decoded SSE payload into the accumulator and returns the
    /// deltas it produced. Throws for provider error events.
    mutating func consume(_ value: JSONValue) throws -> [AssistantMessageEvent] {
        guard let object = value.objectValue, let type = object["type"]?.stringValue else { return [] }
        var events: [AssistantMessageEvent] = []

        switch type {
        case "response.created":
            if let response = object["response"]?.objectValue,
               let id = response["id"]?.stringValue, !id.isEmpty {
                responseId = id
            }

        case "response.output_item.added":
            guard let outputIndex = object["output_index"]?.intValue,
                  let item = object["item"]?.objectValue else { break }
            createSlot(outputIndex: outputIndex, item: item)

        case "response.output_text.delta", "response.refusal.delta":
            guard let outputIndex = object["output_index"]?.intValue,
                  let delta = object["delta"]?.stringValue, !delta.isEmpty else { break }
            if case .text(let contentIndex) = slots[outputIndex] {
                appendText(at: contentIndex, delta)
                events.append(.textDelta(delta))
            }

        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            guard let outputIndex = object["output_index"]?.intValue,
                  let delta = object["delta"]?.stringValue, !delta.isEmpty else { break }
            if case .thinking(let contentIndex) = slots[outputIndex] {
                appendThinking(at: contentIndex, delta)
                events.append(.thinkingDelta(delta))
            }

        case "response.reasoning_summary_part.done":
            guard let outputIndex = object["output_index"]?.intValue else { break }
            if case .thinking(let contentIndex) = slots[outputIndex] {
                appendThinking(at: contentIndex, "\n\n")
                events.append(.thinkingDelta("\n\n"))
            }

        case "response.function_call_arguments.delta":
            guard let outputIndex = object["output_index"]?.intValue,
                  let delta = object["delta"]?.stringValue, !delta.isEmpty else { break }
            if case .toolCall(_, let toolIndex, let callId, let name) = slots[outputIndex] {
                partialArguments[outputIndex, default: ""] += delta
                events.append(.toolCallDelta(
                    index: toolIndex,
                    id: callId,
                    name: name,
                    argumentsFragment: delta
                ))
            }

        case "response.function_call_arguments.done":
            guard let outputIndex = object["output_index"]?.intValue,
                  let arguments = object["arguments"]?.stringValue else { break }
            if case .toolCall(_, let toolIndex, let callId, let name) = slots[outputIndex] {
                let previous = partialArguments[outputIndex] ?? ""
                partialArguments[outputIndex] = arguments
                if arguments.hasPrefix(previous) {
                    let suffix = String(arguments.dropFirst(previous.count))
                    if !suffix.isEmpty {
                        events.append(.toolCallDelta(
                            index: toolIndex,
                            id: callId,
                            name: name,
                            argumentsFragment: suffix
                        ))
                    }
                }
            }

        case "response.output_item.done":
            guard let outputIndex = object["output_index"]?.intValue,
                  let item = object["item"]?.objectValue else { break }
            finalizeSlot(outputIndex: outputIndex, item: item)

        case "response.completed", "response.incomplete":
            if let response = object["response"]?.objectValue {
                finalizeResponse(response)
            } else {
                sawTerminalEvent = true
            }

        case "response.failed":
            sawTerminalEvent = true
            throw OpenAIResponsesStreamError.providerError(Self.failureMessage(object["response"]))

        case "error":
            throw OpenAIResponsesStreamError.providerError(Self.errorEventMessage(object))

        default:
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
            responseId: responseId,
            usage: usage,
            stopReason: stopReason,
            errorMessage: errorMessage,
            rawStopReason: rawStopReason,
            timestamp: timestamp
        )
    }

    // MARK: - Slots

    private mutating func createSlot(outputIndex: Int, item: JSONObject) {
        guard slots[outputIndex] == nil else { return }
        switch item["type"]?.stringValue {
        case "reasoning":
            content.append(.thinking(ThinkingContent(thinking: "")))
            slots[outputIndex] = .thinking(contentIndex: content.count - 1)

        case "message":
            content.append(.text(TextContent(text: "")))
            slots[outputIndex] = .text(contentIndex: content.count - 1)

        case "function_call":
            let callId = item["call_id"]?.stringValue ?? item["id"]?.stringValue ?? ""
            let name = item["name"]?.stringValue ?? ""
            content.append(.toolCall(ToolCall(id: callId, name: name, arguments: .object([:]))))
            let toolIndex = toolCallCount
            toolCallCount += 1
            slots[outputIndex] = .toolCall(
                contentIndex: content.count - 1,
                toolIndex: toolIndex,
                callId: callId,
                name: name
            )
            partialArguments[outputIndex] = item["arguments"]?.stringValue ?? ""

        default:
            break
        }
    }

    private mutating func finalizeSlot(outputIndex: Int, item: JSONObject) {
        if slots[outputIndex] == nil {
            createSlot(outputIndex: outputIndex, item: item)
        }
        guard let slot = slots[outputIndex] else { return }

        switch slot {
        case .thinking(let contentIndex):
            let summary = OpenAIResponsesMapping.joinedText(item["summary"])
            let reasoning = OpenAIResponsesMapping.joinedText(item["content"])
            let thinking = !summary.isEmpty ? summary : reasoning
            if case .thinking(var block) = content[contentIndex], !thinking.isEmpty {
                block.thinking = thinking
                content[contentIndex] = .thinking(block)
            }
            slots[outputIndex] = nil

        case .text(let contentIndex):
            let text = OpenAIResponsesMapping.joinedContent(item["content"])
            if case .text(var block) = content[contentIndex], !text.isEmpty {
                block.text = text
                content[contentIndex] = .text(block)
            }
            slots[outputIndex] = nil

        case .toolCall(let contentIndex, _, let callId, let name):
            let arguments = item["arguments"]?.stringValue ?? partialArguments[outputIndex] ?? "{}"
            let parsed = JSONParse.parse(arguments) ?? .object([:])
            content[contentIndex] = .toolCall(ToolCall(id: callId, name: name, arguments: parsed))
            partialArguments.removeValue(forKey: outputIndex)
            slots[outputIndex] = nil
        }
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

    // MARK: - Terminal response

    private mutating func finalizeResponse(_ response: JSONObject) {
        sawTerminalEvent = true
        if let id = response["id"]?.stringValue, !id.isEmpty {
            responseId = id
        }
        if let usage = response["usage"] {
            self.usage = OpenAIResponsesMapping.parseUsage(usage)
        }

        let status = response["status"]?.stringValue
        let incomplete = response["incomplete_details"] ?? .null
        let incompleteReason = incomplete["reason"].stringValue
        rawStopReason = incompleteReason.map { "\(status ?? "").\($0)" } ?? status

        let mapped = OpenAIResponsesMapping.mapStopReason(status: status, incompleteReason: incompleteReason)
        stopReason = mapped.stopReason
        errorMessage = mapped.errorMessage

        if stopReason == .stop, content.contains(where: { block in
            if case .toolCall = block { return true }
            return false
        }) {
            stopReason = .toolUse
        }
    }

    /// Refuses to hand over tool calls whose `output_item.done` never arrived.
    func validateToolCalls() throws {
        guard stopReason == .toolUse else { return }
        for (outputIndex, _) in partialArguments {
            guard case .toolCall(_, _, _, let name)? = slots[outputIndex] else { continue }
            throw OpenAIResponsesStreamError.unfinishedToolCall(name)
        }
    }

    // MARK: - Failure messages

    private static func failureMessage(_ response: JSONValue?) -> String {
        let object = response?.objectValue
        if let error = object?["error"]?.objectValue {
            let code = error["code"]?.stringValue ?? "unknown"
            let message = error["message"]?.stringValue ?? "no message"
            return "\(code): \(message)"
        }
        if let reason = object?["incomplete_details"]?["reason"].stringValue {
            return "incomplete: \(reason)"
        }
        return "Unknown error (no error details in response)"
    }

    private static func errorEventMessage(_ object: JSONObject) -> String {
        let code = object["code"]?.stringValue
        let message = object["message"]?.stringValue
        if let message {
            return "Error Code \(code ?? "unknown"): \(message)"
        }
        return "Unknown error"
    }
}
