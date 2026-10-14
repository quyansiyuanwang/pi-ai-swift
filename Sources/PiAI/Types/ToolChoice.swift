import Foundation

/// Provider-neutral tool selection for a chat request.
///
/// Mirrors upstream `ToolChoice` (`"auto" | "none"`, `types.ts`) plus the OpenAI
/// Chat Completions extensions (`"required"` and a forced function). Encodes to
/// the JSON `tool_choice` value.
public enum ToolChoice: Sendable, Codable, Equatable, Hashable {
    /// Let the model decide (OpenAI default).
    case auto
    /// Disallow tool calls.
    case none
    /// Force at least one tool call.
    case required
    /// Force a specific function by name.
    case function(name: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case function
        case name
    }

    private enum Kind: String, Codable {
        case function
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let raw = try? single.decode(String.self) {
            switch raw {
            case "auto": self = .auto
            case "none": self = .none
            case "required": self = .required
            default:
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown tool_choice: \(raw)"
                ))
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let function = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .function)
        self = .function(name: try function.decode(String.self, forKey: .name))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .auto:
            try Self.encodeString("auto", to: encoder)
        case .none:
            try Self.encodeString("none", to: encoder)
        case .required:
            try Self.encodeString("required", to: encoder)
        case .function(let name):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.function, forKey: .type)
            var function = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .function)
            try function.encode(name, forKey: .name)
        }
    }

    /// The JSON value used in an OpenAI `tool_choice` field.
    public var jsonValue: JSONValue {
        switch self {
        case .auto: return .string("auto")
        case .none: return .string("none")
        case .required: return .string("required")
        case .function(let name):
            return .object([
                "type": .string("function"),
                "function": .object(["name": .string(name)]),
            ])
        }
    }

    private static func encodeString(_ value: String, to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
