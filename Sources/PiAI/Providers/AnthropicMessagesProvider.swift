import Foundation

/// Anthropic Messages API provider (`anthropic-messages`).
///
/// Swift port of upstream `api/anthropic-messages.ts` for the supported subset:
/// request building, SSE streaming (`message_*` / `content_block_*` events),
/// non-streaming completion, thinking deltas, tool-call accumulation, usage and
/// cancellation. Compat flags, prompt caching, beta headers, Bedrock/Vertex
/// variants and count-tokens are intentionally out of scope.
public struct AnthropicMessagesProvider: ChatCompleting, ChatProvider, Sendable {
    public var httpClient: any HTTPClient
    public var streamingClient: any StreamingHTTPClient
    public var maxRetries: Int
    public var maxRetryDelayMs: Int?
    /// When set, extended thinking is requested with
    /// `thinking: { type: "enabled", budget_tokens: N }`.
    public var reasoningBudgetTokens: Int?

    public init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        streamingClient: (any StreamingHTTPClient)? = nil,
        maxRetries: Int = 0,
        maxRetryDelayMs: Int? = nil,
        reasoningBudgetTokens: Int? = nil
    ) {
        self.httpClient = httpClient
        self.streamingClient = streamingClient
            ?? (httpClient as? any StreamingHTTPClient)
            ?? URLSessionStreamingHTTPClient()
        self.maxRetries = maxRetries
        self.maxRetryDelayMs = maxRetryDelayMs
        self.reasoningBudgetTokens = reasoningBudgetTokens
    }

    // MARK: - Non-streaming

    public func complete(
        model: Model,
        context: ChatContext,
        options: ChatOptions
    ) async throws -> AssistantMessage {
        let request = try AnthropicMessagesRequestBuilder.makeRequest(
            model: model,
            context: context,
            options: options,
            streaming: false,
            reasoningBudgetTokens: reasoningBudgetTokens
        )
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
        return try AnthropicMessagesResponseParser.parse(response.body, model: model)
    }

    // MARK: - Streaming

    /// Streams an assistant response as an `AsyncThrowingStream` of
    /// ``AssistantMessageEvent`` values.
    ///
    /// Cancellation is cooperative: cancelling `options.signal` or the consuming
    /// task interrupts the in-flight request and finishes the stream by
    /// throwing `CancellationError`. Provider/transport failures (including an
    /// `error` event) are delivered as a final `.error` event.
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
        let request = try AnthropicMessagesRequestBuilder.makeRequest(
            model: model,
            context: context,
            options: options,
            streaming: true,
            reasoningBudgetTokens: reasoningBudgetTokens
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
        var parser = AnthropicMessagesStreamParser(model: model, timestamp: OpenAIResponseParser.nowMillis())

        streamLoop: for try await chunk in httpStream.body {
            try checkCancellation(options)
            for payload in decoder.append(chunk) {
                if payload == "[DONE]" { break streamLoop }
                guard let value = JSONParse.parse(payload) else { continue }
                for event in try parser.consume(value) {
                    continuation.yield(event)
                }
            }
        }

        // Flush a final line that was not newline-terminated.
        for payload in decoder.finish() {
            if payload == "[DONE]" { break }
            guard let value = JSONParse.parse(payload) else { continue }
            for event in try parser.consume(value) {
                continuation.yield(event)
            }
        }

        try checkCancellation(options)

        if parser.sawMessageStart && !parser.sawMessageStop {
            throw AnthropicMessagesStreamError.missingTerminalEvent
        }
        guard parser.stopReason != .pending else {
            throw AnthropicMessagesStreamError.missingStopReason
        }

        let message = parser.finalize()
        if message.stopReason == .error {
            throw AnthropicMessagesStreamError.providerError(
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
