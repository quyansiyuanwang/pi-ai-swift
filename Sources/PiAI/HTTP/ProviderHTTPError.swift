import Foundation

/// A rich provider HTTP error.
///
/// Mirrors the upstream SDK error shape consumed by
/// `utils/provider-retry.ts` (`status`, `headers`, `message`) plus the raw body
/// normalized by ``ErrorBody``. Response headers use lowercase keys, matching
/// `Headers` upstream.
public struct ProviderHTTPError: Error, Sendable, Equatable, LocalizedError, CustomStringConvertible {
    /// HTTP status code, or `nil` for a network/transport failure.
    public let status: Int?
    /// Response headers with lowercase keys.
    public let headers: [String: String]
    /// Raw response body, already truncated to ``ErrorBody/maxBodyChars``.
    public let body: String?
    /// Best human-readable message extracted from the body.
    public let message: String

    public var errorDescription: String? { message }
    public var description: String { message }

    public init(status: Int?, headers: [String: String], body: String?, message: String) {
        self.status = status
        self.headers = headers
        self.body = body
        self.message = message
    }

    /// Builds an HTTP error from a non-2xx response.
    public static func http(status: Int, headers: [String: String], body: Data) -> ProviderHTTPError {
        let raw = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let truncatedBody = raw.isEmpty ? nil : ErrorBody.truncate(raw)
        let message = ErrorBody.extractMessage(from: body, fallback: "HTTP \(status)")
        return ProviderHTTPError(status: status, headers: headers, body: truncatedBody, message: message)
    }

    /// Builds a network/transport error with no status or body.
    public static func network(message: String) -> ProviderHTTPError {
        ProviderHTTPError(status: nil, headers: [:], body: nil, message: message)
    }
}
