import Foundation

/// A provider error normalized into the fields used for display.
///
/// Mirrors upstream `NormalizedProviderError` from `utils/error-body.ts`. The
/// Swift port probes the single `ProviderHTTPError` shape produced by
/// ``HTTPClient`` instead of the SDK-specific field shapes (Mistral, `openai`,
/// `@google/genai`, Bedrock) the TypeScript original handles.
public struct NormalizedProviderError: Sendable, Equatable {
    /// HTTP status code, when known.
    public var status: Int?
    /// Raw HTTP body reason, already trimmed and truncated.
    public var body: String?
    /// Human-readable message.
    public var message: String
    /// True when ``message`` already contains the body (no separate body to add).
    public var messageCarriesBody: Bool

    public init(status: Int? = nil, body: String? = nil, message: String, messageCarriesBody: Bool) {
        self.status = status
        self.body = body
        self.message = message
        self.messageCarriesBody = messageCarriesBody
    }
}

/// Shared normalization for provider HTTP errors.
///
/// Direct port of upstream `utils/error-body.ts` for the subset this package
/// needs: normalization, display formatting, truncation, and extracting the
/// most useful human message from a raw response body.
public enum ErrorBody {
    /// Maximum number of raw body characters retained (`4000` upstream).
    public static let maxBodyChars = 4000

    /// Normalizes any thrown error into a displayable shape.
    ///
    /// For a ``ProviderHTTPError`` the status/body/message are used directly.
    /// Every other error falls back to `String(describing:)` with no body.
    public static func normalize(_ error: any Error) -> NormalizedProviderError {
        if let providerError = error as? ProviderHTTPError {
            let carriesBody: Bool
            if let body = providerError.body {
                carriesBody = providerError.message.contains(body)
            } else {
                carriesBody = true
            }
            return NormalizedProviderError(
                status: providerError.status,
                body: providerError.body,
                message: providerError.message,
                messageCarriesBody: carriesBody
            )
        }
        return NormalizedProviderError(
            status: nil,
            body: nil,
            message: String(describing: error),
            messageCarriesBody: false
        )
    }

    /// Composes a display string from a normalized error.
    ///
    /// When the message already carries the body (or no status/body was
    /// extracted) the message is returned unchanged, optionally with a
    /// `prefix (status): ` lead-in. Otherwise the status and body are surfaced.
    public static func format(_ error: NormalizedProviderError, prefix: String? = nil) -> String {
        if error.messageCarriesBody || error.status == nil || error.body == nil {
            if let prefix, let status = error.status {
                return "\(prefix) (\(status)): \(error.message)"
            }
            return error.message
        }
        if let prefix, let status = error.status {
            return "\(prefix) (\(status)): \(error.body ?? "")"
        }
        return "\(error.status.map(String.init) ?? ""): \(error.body ?? "")"
    }

    /// Truncates ``text`` to ``maxChars`` characters, appending a marker that
    /// records how many characters were dropped.
    public static func truncate(_ text: String, maxChars: Int = maxBodyChars) -> String {
        if text.count <= maxChars { return text }
        let kept = String(text.prefix(maxChars))
        return "\(kept)... [truncated \(text.count - maxChars) chars]"
    }

    /// Extracts the most useful human message from a raw response body.
    ///
    /// Probe order (all optional / safe):
    /// 1. JSON string `error`.
    /// 2. JSON string `error.message` or top-level `message`.
    /// 3. JSON string `error.code` / `error.type` (e.g. `"rate_limit_exceeded"`).
    /// 4. JSON string `detail` / `error_description`.
    /// 5. The trimmed raw body when non-empty.
    /// 6. The `fallback` argument (e.g. `"HTTP <status>"`).
    ///
    /// Non-JSON bodies return the trimmed raw text (truncated).
    public static func extractMessage(from body: Data, fallback: String?) -> String {
        guard let raw = String(data: body, encoding: .utf8) else {
            return fallback ?? ""
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback ?? "" }

        if let value = try? JSONDecoder().decode(JSONValue.self, from: body),
           let object = value.objectValue {
            if let string = nonEmpty(object["error"]?.stringValue) { return string }
            if let errorObject = object["error"]?.objectValue {
                if let string = nonEmpty(errorObject["message"]?.stringValue) { return string }
            }
            if let string = nonEmpty(object["message"]?.stringValue) { return string }
            if let errorObject = object["error"]?.objectValue {
                if let string = nonEmpty(errorObject["code"]?.stringValue) { return string }
                if let string = nonEmpty(errorObject["type"]?.stringValue) { return string }
            }
            if let string = nonEmpty(object["code"]?.stringValue) { return string }
            if let string = nonEmpty(object["type"]?.stringValue) { return string }
            if let string = nonEmpty(object["detail"]?.stringValue) { return string }
            if let string = nonEmpty(object["error_description"]?.stringValue) { return string }
            return truncate(trimmed)
        }

        return truncate(trimmed)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
