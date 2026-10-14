import Foundation

/// Why an assistant turn ended. Mirrors upstream `StopReason`.
public enum StopReason: String, Sendable, Codable, Equatable, Hashable {
    case pending
    case stop
    case length
    case toolUse
    case error
    case aborted
    case deferred
}

/// System instructions. Mirrors upstream `SystemMessage` (simplified: prompt
/// sections and incremental tool registration are out of scope for the
/// OpenAI-compatible subset).
public struct SystemMessage: Sendable, Codable, Equatable, Hashable {
    public var content: MessageContent
    /// Unix timestamp in milliseconds.
    public var timestamp: Int

    public init(content: MessageContent, timestamp: Int) {
        self.content = content
        self.timestamp = timestamp
    }

    public init(content: String, timestamp: Int) {
        self.init(content: .text(content), timestamp: timestamp)
    }
}

/// A user message. Mirrors upstream `UserMessage`.
public struct UserMessage: Sendable, Codable, Equatable, Hashable {
    public var content: MessageContent
    /// Unix timestamp in milliseconds.
    public var timestamp: Int

    public init(content: MessageContent, timestamp: Int) {
        self.content = content
        self.timestamp = timestamp
    }

    public init(content: String, timestamp: Int) {
        self.init(content: .text(content), timestamp: timestamp)
    }
}

/// An assistant message. Mirrors upstream `AssistantMessage`.
public struct AssistantMessage: Sendable, Codable, Equatable, Hashable {
    public var content: [ContentBlock]
    public var api: String
    public var provider: String
    public var model: String
    /// Concrete model reported by the provider when different from `model`.
    public var responseModel: String?
    /// Provider-specific response/message identifier.
    public var responseId: String?
    public var usage: Usage
    public var stopReason: StopReason
    public var errorMessage: String?
    public var rawStopReason: String?
    /// Unix timestamp in milliseconds when the request started.
    public var timestamp: Int

    public init(
        content: [ContentBlock] = [],
        api: String = "",
        provider: String = "",
        model: String = "",
        responseModel: String? = nil,
        responseId: String? = nil,
        usage: Usage = .zero,
        stopReason: StopReason = .pending,
        errorMessage: String? = nil,
        rawStopReason: String? = nil,
        timestamp: Int = 0
    ) {
        self.content = content
        self.api = api
        self.provider = provider
        self.model = model
        self.responseModel = responseModel
        self.responseId = responseId
        self.usage = usage
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.rawStopReason = rawStopReason
        self.timestamp = timestamp
    }
}

/// The result of executing a tool. Mirrors upstream `ToolResultMessage`.
public struct ToolResultMessage: Sendable, Codable, Equatable, Hashable {
    public var toolCallId: String
    public var toolName: String
    public var content: [ContentBlock]
    public var details: JSONValue?
    /// Usage from the tool execution itself, if available.
    public var usage: Usage?
    public var isError: Bool
    /// Unix timestamp in milliseconds when the result was created.
    public var timestamp: Int

    public init(
        toolCallId: String,
        toolName: String,
        content: [ContentBlock] = [],
        details: JSONValue? = nil,
        usage: Usage? = nil,
        isError: Bool = false,
        timestamp: Int = 0
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.content = content
        self.details = details
        self.usage = usage
        self.isError = isError
        self.timestamp = timestamp
    }

    public init(
        toolCallId: String,
        toolName: String,
        text: String,
        details: JSONValue? = nil,
        usage: Usage? = nil,
        isError: Bool = false,
        timestamp: Int = 0
    ) {
        self.init(
            toolCallId: toolCallId,
            toolName: toolName,
            content: [.text(TextContent(text: text))],
            details: details,
            usage: usage,
            isError: isError,
            timestamp: timestamp
        )
    }
}

/// Any message in a conversation. Mirrors upstream `Message`.
public enum Message: Sendable, Codable, Equatable, Hashable {
    case system(SystemMessage)
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)

    /// The wire-format role discriminator.
    public var role: String {
        switch self {
        case .system: return "system"
        case .user: return "user"
        case .assistant: return "assistant"
        case .toolResult: return "toolResult"
        }
    }
}

// MARK: - Message Codable

extension Message {
    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let object = value.objectValue, let role = object["role"]?.stringValue else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Message is missing `role`")
            )
        }
        switch role {
        case "system": self = .system(try value.decoded())
        case "user": self = .user(try value.decoded())
        case "assistant": self = .assistant(try value.decoded())
        case "toolResult": self = .toolResult(try value.decoded())
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown message role: \(role)")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .system(let message): try Self.encode(message, role: "system", to: encoder)
        case .user(let message): try Self.encode(message, role: "user", to: encoder)
        case .assistant(let message): try Self.encode(message, role: "assistant", to: encoder)
        case .toolResult(let message): try Self.encode(message, role: "toolResult", to: encoder)
        }
    }

    private static func encode<T: Encodable>(_ value: T, role: String, to encoder: Encoder) throws {
        var object = try JSONValue(encoding: value).objectValue ?? [:]
        object["role"] = .string(role)
        try JSONValue.object(object).encode(to: encoder)
    }
}
