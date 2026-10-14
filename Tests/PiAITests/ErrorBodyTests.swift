import Foundation
import Testing
@testable import PiAI

@Suite struct ErrorBodyTests {
    @Test func normalizeProviderHTTPError() {
        let error = ProviderHTTPError(
            status: 403,
            headers: ["x-request-id": "abc"],
            body: #"{"error":"blocked by gateway WAF"}"#,
            message: "403 status code (no body)"
        )
        let normalized = ErrorBody.normalize(error)
        #expect(normalized.status == 403)
        #expect(normalized.body == #"{"error":"blocked by gateway WAF"}"#)
        #expect(normalized.message == "403 status code (no body)")
        #expect(normalized.messageCarriesBody == false)
    }

    @Test func normalizeSetsMessageCarriesBodyWhenMessageContainsBody() {
        let error = ProviderHTTPError(
            status: 500,
            headers: [:],
            body: "upstream exploded",
            message: "500: upstream exploded"
        )
        let normalized = ErrorBody.normalize(error)
        #expect(normalized.messageCarriesBody == true)
    }

    @Test func normalizeNilBodySetsMessageCarriesBody() {
        let error = ProviderHTTPError.network(message: "connection refused")
        let normalized = ErrorBody.normalize(error)
        #expect(normalized.status == nil)
        #expect(normalized.body == nil)
        #expect(normalized.message == "connection refused")
        #expect(normalized.messageCarriesBody == true)
    }

    @Test func normalizeNonProviderErrorFallsBackToString() {
        struct Boom: Error {}
        let normalized = ErrorBody.normalize(Boom())
        #expect(normalized.status == nil)
        #expect(normalized.body == nil)
        #expect(normalized.messageCarriesBody == false)
        #expect(!normalized.message.isEmpty)
    }

    @Test func truncateLeavesShortTextUntouched() {
        #expect(ErrorBody.truncate("hello", maxChars: 10) == "hello")
        #expect(ErrorBody.truncate("hello", maxChars: 5) == "hello")
    }

    @Test func truncateAppendsMarkerAtBoundary() {
        let text = String(repeating: "x", count: 10)
        #expect(ErrorBody.truncate(text, maxChars: 10) == text)

        let truncated = ErrorBody.truncate(text, maxChars: 4)
        #expect(truncated == "xxxx... [truncated 6 chars]")
    }

    @Test func extractMessageFromErrorMessageObject() {
        let body = Data(#"{"error":{"message":"schema validation failed"}}"#.utf8)
        #expect(ErrorBody.extractMessage(from: body, fallback: nil) == "schema validation failed")
    }

    @Test func extractMessageFromErrorString() {
        let body = Data(#"{"error":"blocked by gateway WAF"}"#.utf8)
        #expect(ErrorBody.extractMessage(from: body, fallback: nil) == "blocked by gateway WAF")
    }

    @Test func extractMessageFromTopLevelMessage() {
        let body = Data(#"{"message":"model not found"}"#.utf8)
        #expect(ErrorBody.extractMessage(from: body, fallback: nil) == "model not found")
    }

    @Test func extractMessageFromErrorCode() {
        let body = Data(#"{"error":{"code":"rate_limit_exceeded"}}"#.utf8)
        #expect(ErrorBody.extractMessage(from: body, fallback: nil) == "rate_limit_exceeded")
    }

    @Test func extractMessageFromDetail() {
        let body = Data(#"{"detail":"invalid api key"}"#.utf8)
        #expect(ErrorBody.extractMessage(from: body, fallback: nil) == "invalid api key")
    }

    @Test func extractMessageFromErrorDescription() {
        let body = Data(#"{"error_description":"token expired"}"#.utf8)
        #expect(ErrorBody.extractMessage(from: body, fallback: nil) == "token expired")
    }

    @Test func extractMessageFromNonJSONBody() {
        let body = Data("  upstream is down  ".utf8)
        #expect(ErrorBody.extractMessage(from: body, fallback: nil) == "upstream is down")
    }

    @Test func extractMessageEmptyBodyUsesFallback() {
        #expect(ErrorBody.extractMessage(from: Data(), fallback: "HTTP 500") == "HTTP 500")
        #expect(ErrorBody.extractMessage(from: Data("   ".utf8), fallback: "HTTP 500") == "HTTP 500")
    }

    @Test func extractMessageUnknownJSONFallsBackToRawBody() {
        let raw = #"{"unexpected":true}"#
        let body = Data(raw.utf8)
        #expect(ErrorBody.extractMessage(from: body, fallback: nil) == raw)
    }

    @Test func providerHTTPErrorFactoryExtractsMessageAndTruncatesBody() {
        let body = Data(#"{"error":{"message":"nope"}}"#.utf8)
        let error = ProviderHTTPError.http(status: 400, headers: ["retry-after-ms": "5"], body: body)
        #expect(error.status == 400)
        #expect(error.message == "nope")
        #expect(error.body == #"{"error":{"message":"nope"}}"#)
        #expect(error.headers["retry-after-ms"] == "5")

        let longBody = Data(String(repeating: "x", count: 4100).utf8)
        let longError = ProviderHTTPError.http(status: 500, headers: [:], body: longBody)
        #expect(longError.body?.contains("... [truncated 100 chars]") == true)
    }

    @Test func providerHTTPErrorFactoryEmptyBodyUsesHTTPFallback() {
        let error = ProviderHTTPError.http(status: 502, headers: [:], body: Data())
        #expect(error.body == nil)
        #expect(error.message == "HTTP 502")
    }

    @Test func formatSurfacesStatusAndBody() {
        let normalized = NormalizedProviderError(
            status: 403,
            body: #"{"error":"blocked"}"#,
            message: "403 status code (no body)",
            messageCarriesBody: false
        )
        #expect(ErrorBody.format(normalized) == #"403: {"error":"blocked"}"#)
        #expect(ErrorBody.format(normalized, prefix: "OpenAI API error") == #"OpenAI API error (403): {"error":"blocked"}"#)
    }

    @Test func formatPreservesMessageWhenItCarriesBody() {
        let normalized = NormalizedProviderError(
            status: 403,
            body: "Permission denied",
            message: "Permission denied",
            messageCarriesBody: true
        )
        #expect(ErrorBody.format(normalized) == "Permission denied")
        #expect(ErrorBody.format(normalized, prefix: "OpenAI API error") == "OpenAI API error (403): Permission denied")
    }

    @Test func formatBareMessageWithoutStatusIgnoresPrefix() {
        let normalized = NormalizedProviderError(message: "boom", messageCarriesBody: false)
        #expect(ErrorBody.format(normalized, prefix: "OpenAI API error") == "boom")
    }
}
