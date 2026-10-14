import Foundation

/// Errors surfaced by the streaming OpenAI-compatible provider.
public enum OpenAIStreamError: Error, Sendable, Equatable, LocalizedError {
    /// The transport finished cleanly (no `[DONE]`) without any
    /// `finish_reason`, so the response is considered incomplete.
    case missingFinishReason
    /// The provider returned an error `finish_reason` (e.g. `content_filter`).
    case providerStopReason(String)

    public var errorDescription: String? {
        switch self {
        case .missingFinishReason:
            return "Stream ended without finish_reason"
        case .providerStopReason(let message):
            return message
        }
    }
}

/// Incremental parser for OpenAI-compatible `ChatCompletionChunk` objects.
///
/// Stateful accumulator that folds streamed deltas into content blocks and
/// emits the simplified ``AssistantMessageEvent`` deltas. Mirrors the streaming
/// loop of upstream `api/openai-completions.ts`:
/// - reasoning fields (`reasoning_content` / `reasoning` / `reasoning_text`)
///   become thinking deltas and never leak into the answer text;
/// - `delta.tool_calls[]` is accumulated by `index` (id, function name, and the
///   concatenated `function.arguments` fragments), with arguments parsed only
///   once at the end;
/// - block order follows first appearance so `done` preserves reasoning →
///   text → tool-call ordering.
struct OpenAIStreamParser {
    private let model: Model
    private let timestamp: Int

    private enum BlockKey: Hashable {
        case thinking
        case text
        case toolCall(Int)
    }

    private struct ToolCallAccumulator {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var order: [BlockKey] = []
    private var text = ""
    private var thinking = ""
    private var thinkingSignature: String?
    private var toolCalls: [Int: ToolCallAccumulator] = [:]
    private var fallbackToolIndex = 0

    private(set) var responseId: String?
    private(set) var responseModel: String?
    private(set) var usage: Usage = .zero
    private(set) var stopReason: StopReason = .pending
    private(set) var rawStopReason: String?
    private(set) var errorMessage: String?
    private(set) var hasFinishReason = false

    private static let reasoningFields = ["reasoning_content", "reasoning", "reasoning_text"]

    init(model: Model, timestamp: Int) {
        self.model = model
        self.timestamp = timestamp
    }

    /// Folds one decoded chunk object into the accumulator and returns the
    /// deltas it produced.
    mutating func consume(_ value: JSONValue) -> [AssistantMessageEvent] {
        guard let object = value.objectValue else { return [] }
        var events: [AssistantMessageEvent] = []

        if responseId == nil, let id = object["id"]?.stringValue, !id.isEmpty {
            responseId = id
        }
        if responseModel == nil, let reported = object["model"]?.stringValue,
           !reported.isEmpty, reported != model.id {
            responseModel = reported
        }
        if let usageValue = object["usage"], !usageValue.isNull {
            usage = OpenAIResponseParser.parseUsage(usageValue)
        }

        guard let choice = object["choices"]?.arrayValue?.first?.objectValue else { return events }

        if let finish = choice["finish_reason"]?.stringValue {
            rawStopReason = finish
            let mapped = OpenAIResponseParser.mapStopReason(finish)
            stopReason = mapped.stopReason
            errorMessage = mapped.errorMessage
            hasFinishReason = true
        } else if let usageValue = choice["usage"], !usageValue.isNull {
            // Some providers (e.g. Moonshot) report usage on the choice.
            usage = OpenAIResponseParser.parseUsage(usageValue)
        }

        guard let delta = choice["delta"]?.objectValue else { return events }

        // Reasoning first so the thinking block precedes text in `done`.
        for field in Self.reasoningFields {
            guard let value = delta[field]?.stringValue, !value.isEmpty else { continue }
            if !order.contains(.thinking) { order.append(.thinking) }
            thinking += value
            if thinkingSignature == nil {
                thinkingSignature = (model.provider == "opencode-go" && field == "reasoning")
                    ? "reasoning_content"
                    : field
            }
            events.append(.thinkingDelta(value))
            break
        }

        if let content = delta["content"]?.stringValue, !content.isEmpty {
            if !order.contains(.text) { order.append(.text) }
            text += content
            events.append(.textDelta(content))
        }

        if let toolCallDeltas = delta["tool_calls"]?.arrayValue {
            for rawToolCall in toolCallDeltas {
                guard let toolCall = rawToolCall.objectValue else { continue }
                let index = resolveIndex(for: toolCall)
                if toolCalls[index] == nil {
                    toolCalls[index] = ToolCallAccumulator()
                    order.append(.toolCall(index))
                }

                var accumulator = toolCalls[index] ?? ToolCallAccumulator()
                if let id = toolCall["id"]?.stringValue, !id.isEmpty { accumulator.id = id }

                let function = toolCall["function"]?.objectValue
                let name = function?["name"]?.stringValue
                if let name, !name.isEmpty { accumulator.name = name }

                let fragment = function?["arguments"]?.stringValue ?? ""
                accumulator.arguments += fragment
                toolCalls[index] = accumulator

                events.append(.toolCallDelta(
                    index: index,
                    id: toolCall["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                    name: name,
                    argumentsFragment: fragment
                ))
            }
        }

        return events
    }

    /// Assigns a stable accumulation index. Prefers the provider `index`, then
    /// an existing entry with the same `id`, then a sequential fallback.
    private mutating func resolveIndex(for toolCall: JSONObject) -> Int {
        if let explicit = toolCall["index"]?.intValue { return explicit }
        if let id = toolCall["id"]?.stringValue, !id.isEmpty,
           let existing = toolCalls.first(where: { $0.value.id == id })?.key {
            return existing
        }
        defer { fallbackToolIndex += 1 }
        return fallbackToolIndex
    }

    /// When a clean stream ends (`[DONE]` or EOF) without a `finish_reason`,
    /// infer the stop reason from the accumulated content.
    mutating func inferStopReason() {
        guard stopReason == .pending else { return }
        stopReason = toolCalls.isEmpty ? .stop : .toolUse
    }

    /// Builds the final assistant message from the accumulated state.
    func finalize() -> AssistantMessage {
        var content: [ContentBlock] = []
        for key in order {
            switch key {
            case .thinking:
                content.append(.thinking(ThinkingContent(thinking: thinking, thinkingSignature: thinkingSignature)))
            case .text:
                content.append(.text(TextContent(text: text)))
            case .toolCall(let index):
                guard let accumulator = toolCalls[index] else { continue }
                let arguments = JSONParse.parse(accumulator.arguments) ?? .object([:])
                content.append(.toolCall(ToolCall(
                    id: accumulator.id,
                    name: accumulator.name,
                    arguments: arguments
                )))
            }
        }

        return AssistantMessage(
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
}
