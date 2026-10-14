import Foundation

/// Non-streaming OpenAI-compatible Chat Completions provider.
///
/// Builds a request with ``OpenAIRequestBuilder``, sends it through a
/// ``HTTPClient`` with ``ProviderRetry`` retry policy, and parses the response
/// with ``OpenAIResponseParser``. This is a Swift-specific derivation of the
/// upstream streaming-only `openai-completions` provider.
public struct OpenAICompletionsProvider: ChatCompleting, Sendable {
    public var httpClient: any HTTPClient
    public var maxRetries: Int
    public var maxRetryDelayMs: Int?

    public init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        maxRetries: Int = 0,
        maxRetryDelayMs: Int? = nil
    ) {
        self.httpClient = httpClient
        self.maxRetries = maxRetries
        self.maxRetryDelayMs = maxRetryDelayMs
    }

    public func complete(
        model: Model,
        context: ChatContext,
        options: ChatOptions
    ) async throws -> AssistantMessage {
        let request = try OpenAIRequestBuilder.makeRequest(model: model, context: context, options: options)
        let response = try await ProviderRetry.retry(
            ProviderRetryOptions(
                maxRetries: maxRetries,
                maxRetryDelayMs: maxRetryDelayMs,
                signal: options.signal
            )
        ) {
            try await self.httpClient.send(request)
        }

        if options.signal?.isCancelled == true { throw CancellationError() }
        return try OpenAIResponseParser.parse(response.body, model: model)
    }
}
