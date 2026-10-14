import Foundation

/// OpenAI-compatible Chat Completions provider.
///
/// Supports both the non-streaming path (``complete(model:context:options:)``,
/// M2) and the streaming SSE path
/// (``stream(model:context:options:)``, M3). Swift-specific derivation of the
/// upstream streaming-only `openai-completions` provider.
public struct OpenAICompletionsProvider: ChatCompleting, ChatProvider, Sendable {
    public var httpClient: any HTTPClient
    public var streamingClient: any StreamingHTTPClient
    public var maxRetries: Int
    public var maxRetryDelayMs: Int?

    public init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        streamingClient: (any StreamingHTTPClient)? = nil,
        maxRetries: Int = 0,
        maxRetryDelayMs: Int? = nil
    ) {
        self.httpClient = httpClient
        self.streamingClient = streamingClient
            ?? (httpClient as? any StreamingHTTPClient)
            ?? URLSessionStreamingHTTPClient()
        self.maxRetries = maxRetries
        self.maxRetryDelayMs = maxRetryDelayMs
    }

    // MARK: - Non-streaming

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

    // MARK: - Streaming

    /// Streams an assistant response as an `AsyncThrowingStream` of
    /// ``AssistantMessageEvent`` values.
    ///
    /// Cancellation is cooperative: cancelling `options.signal` or the consuming
    /// task interrupts the in-flight request and finishes the stream by
    /// throwing `CancellationError` (never a retryable network error).
    /// Provider/transport failures are delivered as a final `.error` event.
    public func stream(
        model: Model,
        context: ChatContext,
        options: ChatOptions
    ) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.produce(
                        model: model,
                        context: context,
                        options: options,
                        continuation: continuation
                    )
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    if Task.isCancelled || options.signal?.isCancelled == true {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.yield(.error(error))
                        continuation.finish()
                    }
                }
            }
            options.signal?.onCancel { task.cancel() }
            continuation.onTermination = { termination in
                task.cancel()
                // `AsyncThrowingStream` otherwise finishes iteration with `nil`
                // when the consuming task is cancelled; surface a
                // `CancellationError` instead so callers can distinguish
                // cancellation from a clean end.
                if case .cancelled = termination {
                    continuation.finish(throwing: CancellationError())
                }
            }
        }
    }

    private func produce(
        model: Model,
        context: ChatContext,
        options: ChatOptions,
        continuation: AsyncThrowingStream<AssistantMessageEvent, any Error>.Continuation
    ) async throws {
        let request = try OpenAIRequestBuilder.makeRequest(
            model: model,
            context: context,
            options: options,
            streaming: true
        )

        let httpStream = try await ProviderRetry.retry(
            ProviderRetryOptions(
                maxRetries: maxRetries,
                maxRetryDelayMs: maxRetryDelayMs,
                signal: options.signal
            )
        ) {
            try await self.streamingClient.stream(request)
        }

        try checkCancellation(options)
        continuation.yield(.start)

        var decoder = SSEFrameDecoder()
        var parser = OpenAIStreamParser(model: model, timestamp: OpenAIResponseParser.nowMillis())
        var sawDone = false

        streamLoop: for try await chunk in httpStream.body {
            try checkCancellation(options)
            for payload in decoder.append(chunk) {
                if payload == "[DONE]" {
                    sawDone = true
                    break streamLoop
                }
                guard let value = JSONParse.parse(payload) else { continue }
                for event in parser.consume(value) {
                    continuation.yield(event)
                }
            }
        }

        // Flush a final line that was not newline-terminated.
        if !sawDone {
            for payload in decoder.finish() {
                if payload == "[DONE]" {
                    sawDone = true
                    break
                }
                guard let value = JSONParse.parse(payload) else { continue }
                for event in parser.consume(value) {
                    continuation.yield(event)
                }
            }
        }

        try checkCancellation(options)

        if !parser.hasFinishReason {
            if sawDone {
                parser.inferStopReason()
            } else {
                throw OpenAIStreamError.missingFinishReason
            }
        }

        let message = parser.finalize()
        if message.stopReason == .error {
            throw OpenAIStreamError.providerStopReason(
                message.errorMessage ?? "Provider returned an error stop reason"
            )
        }

        continuation.yield(.done(message))
        continuation.finish()
    }

    private func checkCancellation(_ options: ChatOptions) throws {
        if Task.isCancelled || options.signal?.isCancelled == true {
            throw CancellationError()
        }
    }
}
