import Foundation

/// Google Generative AI (Gemini) provider (`google-generative-ai`).
///
/// Swift port of upstream `api/google-generative-ai.ts` for the supported
/// subset: request building, SSE streaming (`alt=sse`), non-streaming
/// completion, thought parts, tool calls, usage and cancellation. Vertex AI,
/// OAuth, prompt caching, safety-setting overrides, Gemini 3 thinking-level
/// control and media generation are intentionally out of scope; thinking is
/// configured with a token budget only.
public struct GoogleGenerativeAIProvider: ChatCompleting, ChatProvider, Sendable {
    public var httpClient: any HTTPClient
    public var streamingClient: any StreamingHTTPClient
    public var maxRetries: Int
    public var maxRetryDelayMs: Int?
    /// When set, thinking is requested with
    /// `generationConfig.thinkingConfig.thinkingBudget = N`.
    public var thinkingBudget: Int?

    public init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        streamingClient: (any StreamingHTTPClient)? = nil,
        maxRetries: Int = 0,
        maxRetryDelayMs: Int? = nil,
        thinkingBudget: Int? = nil
    ) {
        self.httpClient = httpClient
        self.streamingClient = streamingClient
            ?? (httpClient as? any StreamingHTTPClient)
            ?? URLSessionStreamingHTTPClient()
        self.maxRetries = maxRetries
        self.maxRetryDelayMs = maxRetryDelayMs
        self.thinkingBudget = thinkingBudget
    }

    // MARK: - Non-streaming

    public func complete(
        model: Model,
        context: ChatContext,
        options: ChatOptions
    ) async throws -> AssistantMessage {
        let request = try GoogleGenerativeAIRequestBuilder.makeRequest(
            model: model,
            context: context,
            options: options,
            streaming: false,
            thinkingBudget: thinkingBudget
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
        return try GoogleGenerativeAIResponseParser.parse(response.body, model: model)
    }

    // MARK: - Streaming

    /// Streams an assistant response as an `AsyncThrowingStream` of
    /// ``AssistantMessageEvent`` values.
    ///
    /// Cancellation is cooperative: cancelling `options.signal` or the consuming
    /// task interrupts the in-flight request and finishes the stream by
    /// throwing `CancellationError`. Provider/transport failures are delivered
    /// as a final `.error` event.
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
        let request = try GoogleGenerativeAIRequestBuilder.makeRequest(
            model: model,
            context: context,
            options: options,
            streaming: true,
            thinkingBudget: thinkingBudget
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
        var parser = GoogleGenerativeAIStreamParser(
            model: model,
            timestamp: OpenAIResponseParser.nowMillis()
        )

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

        guard parser.stopReason != .pending else {
            throw GoogleGenerativeAIStreamError.missingStopReason
        }

        let message = parser.finalize()
        if message.stopReason == .error {
            throw GoogleGenerativeAIStreamError.providerError(
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
