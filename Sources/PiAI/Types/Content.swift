import Foundation

/// A text block in a message. Mirrors upstream `TextContent`.
public struct TextContent: Sendable, Codable, Equatable, Hashable {
    public var text: String
    /// Provider-specific opaque signature (e.g. OpenAI Responses metadata).
    public var textSignature: String?

    public init(text: String, textSignature: String? = nil) {
        self.text = text
        self.textSignature = textSignature
    }
}

/// A reasoning/thinking block. Mirrors upstream `ThinkingContent`.
public struct ThinkingContent: Sendable, Codable, Equatable, Hashable {
    public var thinking: String
    /// Provider-specific opaque or serialized reasoning replay data.
    public var thinkingSignature: String?
    /// True when the content was redacted by safety filters.
    public var redacted: Bool?

    public init(thinking: String, thinkingSignature: String? = nil, redacted: Bool? = nil) {
        self.thinking = thinking
        self.thinkingSignature = thinkingSignature
        self.redacted = redacted
    }
}

/// An image block. Mirrors upstream `ImageContent`.
public struct ImageContent: Sendable, Codable, Equatable, Hashable {
    /// Base64 encoded image data.
    public var data: String
    /// e.g. `image/jpeg`, `image/png`.
    public var mimeType: String

    public init(data: String, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// A tool call requested by the assistant. Mirrors upstream `ToolCall`.
public struct ToolCall: Sendable, Codable, Equatable, Hashable {
    public var id: String
    public var name: String
    /// Parsed JSON arguments. Upstream types this as `JsonObject`; we keep the
    /// general ``JSONValue`` and expose ``argumentsObject`` for convenience.
    public var arguments: JSONValue
    /// Google-specific opaque signature for reusing thought context.
    public var thoughtSignature: String?
    /// OpenAI Responses namespace for namespaced tools.
    public var namespace: String?

    public init(
        id: String,
        name: String,
        arguments: JSONValue = .object([:]),
        thoughtSignature: String? = nil,
        namespace: String? = nil
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.thoughtSignature = thoughtSignature
        self.namespace = namespace
    }

    /// The arguments as a JSON object when they are object-shaped.
    public var argumentsObject: JSONObject? {
        arguments.objectValue
    }
}

/// A discriminated union of every content block kind.
public enum ContentBlock: Sendable, Codable, Equatable, Hashable {
    case text(TextContent)
    case thinking(ThinkingContent)
    case image(ImageContent)
    case toolCall(ToolCall)
}

// MARK: - ContentBlock Codable

extension ContentBlock {
    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let object = value.objectValue, let type = object["type"]?.stringValue else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Content block is missing `type`")
            )
        }
        switch type {
        case "text":
            self = .text(try value.decoded())
        case "thinking":
            self = .thinking(try value.decoded())
        case "image":
            self = .image(try value.decoded())
        case "toolCall":
            self = .toolCall(try value.decoded())
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown content block type: \(type)")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let content): try Self.encode(content, type: "text", to: encoder)
        case .thinking(let content): try Self.encode(content, type: "thinking", to: encoder)
        case .image(let content): try Self.encode(content, type: "image", to: encoder)
        case .toolCall(let content): try Self.encode(content, type: "toolCall", to: encoder)
        }
    }

    private static func encode<T: Encodable>(_ value: T, type: String, to encoder: Encoder) throws {
        var object = try JSONValue(encoding: value).objectValue ?? [:]
        object["type"] = .string(type)
        try JSONValue.object(object).encode(to: encoder)
    }
}

// MARK: - Message content

/// User message content: either a plain string or a list of content blocks.
public enum MessageContent: Sendable, Codable, Equatable, Hashable {
    case text(String)
    case blocks([ContentBlock])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
            return
        }
        self = .blocks(try container.decode([ContentBlock].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string): try container.encode(string)
        case .blocks(let blocks): try container.encode(blocks)
        }
    }

    /// The plain text, if this content is a string.
    public var textValue: String? {
        if case .text(let string) = self { return string }
        return nil
    }
}
