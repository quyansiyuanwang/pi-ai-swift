import Foundation

/// Errors surfaced by the streaming Google Generative AI provider.
public enum GoogleGenerativeAIStreamError: Error, Sendable, Equatable, LocalizedError {
    /// The transport finished without a `finishReason`.
    case missingStopReason
    /// The provider returned an error stop reason.
    case providerError(String)

    public var errorDescription: String? {
        switch self {
        case .missingStopReason:
            return "Google stream ended without a finish reason"
        case .providerError(let message):
            return message
        }
    }
}

/// Shared field mapping for streaming and non-streaming Google payloads.
enum GoogleGenerativeAIMapping {
    /// Maps a Gemini `finishReason` to a pi ``StopReason``.
    ///
    /// `STOP` maps to `.stop`, `MAX_TOKENS` to `.length`; every safety or
    /// malformed-tool reason maps to `.error`. The caller promotes `.stop` to
    /// `.toolUse` when a function call is present.
    static func mapStopReason(_ reason: String?) -> (stopReason: StopReason, errorMessage: String?) {
        guard let reason else { return (.stop, nil) }
        switch reason {
        case "STOP":
            return (.stop, nil)
        case "MAX_TOKENS":
            return (.length, nil)
        default:
            return (.error, "Provider stopped with: \(reason)")
        }
    }

    /// Parses a Gemini `usageMetadata` object.
    ///
    /// `promptTokenCount` includes cached content, so the cache read is
    /// subtracted from ``Usage/input``; thought tokens are folded into
    /// ``Usage/output`` and recorded as ``Usage/reasoning``.
    static func parseUsage(_ value: JSONValue) -> Usage {
        let prompt = value["promptTokenCount"].intValue ?? 0
        let cached = value["cachedContentTokenCount"].intValue ?? 0
        let candidates = value["candidatesTokenCount"].intValue ?? 0
        let thoughts = value["thoughtsTokenCount"].intValue ?? 0
        let total = value["totalTokenCount"].intValue ?? 0
        return Usage(
            input: max(0, prompt - cached),
            output: candidates + thoughts,
            cacheRead: cached,
            cacheWrite: 0,
            reasoning: thoughts,
            totalTokens: total,
            cost: .zero
        )
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Retains the last non-empty signature for a streamed block.
    static func retainSignature(_ existing: String?, _ incoming: String?) -> String? {
        guard let incoming, !incoming.isEmpty else { return existing }
        return incoming
    }

    /// Thought signatures must be base64 for Google APIs (`TYPE_BYTES`).
    static func isValidThoughtSignature(_ signature: String?) -> Bool {
        guard let signature, !signature.isEmpty, signature.count % 4 == 0 else { return false }
        for scalar in signature.unicodeScalars {
            let value = scalar.value
            let isAlphaNumeric = (value >= 0x41 && value <= 0x5A)
                || (value >= 0x61 && value <= 0x7A)
                || (value >= 0x30 && value <= 0x39)
            if !(isAlphaNumeric || scalar == "+" || scalar == "/" || scalar == "=") {
                return false
            }
        }
        return true
    }

    static func jsonString(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// Generates a unique tool-call id in the upstream
    /// `{name}_{timestamp}_{counter}` shape.
    static func generatedToolCallID(name: String, timestamp: Int) -> String {
        "\(name)_\(timestamp)_\(toolCallSequence.next())"
    }

    private static let toolCallSequence = ToolCallSequence()
}

/// Lock-protected counter for generated tool-call ids.
private final class ToolCallSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Incremental parser for Google Generative AI (`alt=sse`) responses.
///
/// Folds `GenerateContentResponse` objects into content blocks and emits the
/// simplified ``AssistantMessageEvent`` deltas, mirroring the streaming loop of
/// upstream `api/google-generative-ai.ts`:
/// - `parts[].text` is appended to the active text block; `thought: true` parts
///   become thinking deltas;
/// - `functionCall` parts carry complete arguments (no fragments) and create a
///   tool-call block;
/// - `usageMetadata` and `finishReason` update usage and the stop reason.
struct GoogleGenerativeAIStreamParser {
    private let model: Model
    private let timestamp: Int

    private enum ActiveBlock {
        case text(index: Int)
        case thinking(index: Int)
    }

    private var content: [ContentBlock] = []
    private var activeBlock: ActiveBlock?
    private var toolCallCount = 0

    private(set) var responseId: String?
    private(set) var usage: Usage = .zero
    private(set) var stopReason: StopReason = .pending
    private(set) var rawStopReason: String?
    private(set) var errorMessage: String?
    private(set) var sawFinishReason = false

    init(model: Model, timestamp: Int) {
        self.model = model
        self.timestamp = timestamp
    }

    /// Folds one decoded response object into the accumulator and returns the
    /// deltas it produced.
    mutating func consume(_ value: JSONValue) throws -> [AssistantMessageEvent] {
        guard let object = value.objectValue else { return [] }
        var events: [AssistantMessageEvent] = []

        if responseId == nil, let id = object["responseId"]?.stringValue, !id.isEmpty {
            responseId = id
        }

        if let usageValue = object["usageMetadata"], !usageValue.isNull {
            usage = model.applyingCost(to: GoogleGenerativeAIMapping.parseUsage(usageValue))
        }

        guard let candidate = object["candidates"]?.arrayValue?.first?.objectValue else {
            return events
        }

        if let parts = candidate["content"]?["parts"].arrayValue {
            for partValue in parts {
                guard let part = partValue.objectValue else { continue }

                if let text = part["text"]?.stringValue, !text.isEmpty {
                    let signature = GoogleGenerativeAIMapping.nonEmpty(part["thoughtSignature"]?.stringValue)
                    if part["thought"]?.boolValue == true {
                        appendThinking(text, signature: signature)
                        events.append(.thinkingDelta(text))
                    } else {
                        appendText(text, signature: signature)
                        events.append(.textDelta(text))
                    }
                }

                if let functionCall = part["functionCall"]?.objectValue {
                    let name = functionCall["name"]?.stringValue ?? ""
                    let arguments = functionCall["args"]?.objectValue.map { JSONValue.object($0) } ?? .object([:])
                    let providedID = GoogleGenerativeAIMapping.nonEmpty(functionCall["id"]?.stringValue)
                    let id: String
                    if let providedID, !content.contains(where: { block in
                        if case .toolCall(let call) = block { return call.id == providedID }
                        return false
                    }) {
                        id = providedID
                    } else {
                        id = GoogleGenerativeAIMapping.generatedToolCallID(name: name, timestamp: timestamp)
                    }
                    let signature = GoogleGenerativeAIMapping.nonEmpty(part["thoughtSignature"]?.stringValue)
                    content.append(.toolCall(ToolCall(
                        id: id,
                        name: name,
                        arguments: arguments,
                        thoughtSignature: signature
                    )))
                    activeBlock = nil
                    let toolIndex = toolCallCount
                    toolCallCount += 1
                    events.append(.toolCallDelta(
                        index: toolIndex,
                        id: id,
                        name: name,
                        argumentsFragment: GoogleGenerativeAIMapping.jsonString(arguments)
                    ))
                }
            }
        }

        if let reason = candidate["finishReason"]?.stringValue {
            rawStopReason = reason
            let mapped = GoogleGenerativeAIMapping.mapStopReason(reason)
            stopReason = mapped.stopReason
            errorMessage = mapped.errorMessage
            sawFinishReason = true
            if stopReason == .stop, content.contains(where: { block in
                if case .toolCall = block { return true }
                return false
            }) {
                stopReason = .toolUse
            }
        }

        return events
    }

    /// Infers a stop reason from the accumulated content when the provider
    /// omitted `finishReason` (non-streaming responses).
    mutating func inferStopReason() {
        guard stopReason == .pending else { return }
        stopReason = content.contains(where: { block in
            if case .toolCall = block { return true }
            return false
        }) ? .toolUse : .stop
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

    // MARK: - Block accumulation

    @discardableResult
    private mutating func appendText(_ delta: String, signature: String?) -> Int {
        let index: Int
        if case .text(let existing)? = activeBlock {
            index = existing
        } else {
            content.append(.text(TextContent(text: "")))
            index = content.count - 1
            activeBlock = .text(index: index)
        }
        if case .text(var block) = content[index] {
            block.text += delta
            block.textSignature = GoogleGenerativeAIMapping.retainSignature(block.textSignature, signature)
            content[index] = .text(block)
        }
        return index
    }

    private mutating func appendThinking(_ delta: String, signature: String?) {
        let index: Int
        if case .thinking(let existing)? = activeBlock {
            index = existing
        } else {
            content.append(.thinking(ThinkingContent(thinking: "")))
            index = content.count - 1
            activeBlock = .thinking(index: index)
        }
        if case .thinking(var block) = content[index] {
            block.thinking += delta
            block.thinkingSignature = GoogleGenerativeAIMapping.retainSignature(block.thinkingSignature, signature)
            content[index] = .thinking(block)
        }
    }
}
