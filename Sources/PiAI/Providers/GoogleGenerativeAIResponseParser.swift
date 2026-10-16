import Foundation

/// Errors surfaced while parsing a non-streaming Google Generative AI payload.
public enum GoogleGenerativeAIResponseError: Error, Sendable, Equatable, LocalizedError {
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .malformedResponse:
            return "Google Generative AI payload is not a JSON object"
        }
    }
}

/// Parses a full (non-streaming) Google Generative AI response.
///
/// Upstream is streaming-only; this is a Swift-specific derivation that feeds
/// the single `GenerateContentResponse` object through the streaming parser so
/// both paths share identical content, usage and stop-reason handling.
public enum GoogleGenerativeAIResponseParser {
    public static func parse(_ data: Data, model: Model) throws -> AssistantMessage {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw GoogleGenerativeAIResponseError.malformedResponse
        }
        return try parse(value, model: model)
    }

    public static func parse(_ value: JSONValue, model: Model) throws -> AssistantMessage {
        guard value.objectValue != nil else {
            throw GoogleGenerativeAIResponseError.malformedResponse
        }
        var parser = GoogleGenerativeAIStreamParser(
            model: model,
            timestamp: OpenAIResponseParser.nowMillis()
        )
        _ = try parser.consume(value)
        parser.inferStopReason()
        return parser.finalize()
    }
}
