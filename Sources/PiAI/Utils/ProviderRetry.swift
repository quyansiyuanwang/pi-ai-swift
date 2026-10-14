import Foundation

/// Options controlling ``ProviderRetry``.
///
/// Mirrors upstream `ProviderRetryOptions` from `utils/provider-retry.ts`, plus
/// test seams (`baseBackoffMs`, `maxBackoffMs`, `jitterFraction`, `random`,
/// `sleep`) so the backoff policy can be asserted deterministically.
public struct ProviderRetryOptions: Sendable {
    /// Number of retries after the initial attempt. Default `0`.
    public var maxRetries: Int
    /// Maximum server-requested delay in milliseconds. `nil` => `60000`;
    /// `0` disables the cap.
    public var maxRetryDelayMs: Int?
    /// HTTP statuses that fail immediately even though the default policy
    /// would retry them.
    public var noRetryStatuses: [Int]
    /// Optional cancellation signal checked before each attempt and during sleep.
    public var signal: CancellationSignal?
    /// Base exponential backoff in milliseconds. Mirrors the pinned SDK policy.
    public var baseBackoffMs: Int
    /// Exponential backoff ceiling in milliseconds.
    public var maxBackoffMs: Int
    /// Jitter fraction applied to exponential delays: `delay *= 1 - random * fraction`.
    public var jitterFraction: Double
    /// Random source in `0..<1` used for jitter.
    public var random: @Sendable () -> Double
    /// Sleep implementation. Defaults to an abortable sleep honoring ``signal``.
    public var sleep: @Sendable (Int) async throws -> Void

    public init(
        maxRetries: Int = 0,
        maxRetryDelayMs: Int? = nil,
        noRetryStatuses: [Int] = [],
        signal: CancellationSignal? = nil,
        baseBackoffMs: Int = 500,
        maxBackoffMs: Int = 8000,
        jitterFraction: Double = 0.25,
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        sleep: (@Sendable (Int) async throws -> Void)? = nil
    ) {
        self.maxRetries = maxRetries
        self.maxRetryDelayMs = maxRetryDelayMs
        self.noRetryStatuses = noRetryStatuses
        self.signal = signal
        self.baseBackoffMs = baseBackoffMs
        self.maxBackoffMs = maxBackoffMs
        self.jitterFraction = jitterFraction
        self.random = random
        self.sleep = sleep ?? { milliseconds in
            try await ProviderRetry.abortableSleep(milliseconds: milliseconds, signal: signal)
        }
    }
}

/// Provider request retry helper.
///
/// Reproduces the retry policy pinned by the OpenAI/Anthropic SDKs while making
/// backoff sleeps interruptible. Callers invoke the transport with retries
/// disabled and wrap the call with ``retry(_:_:)``.
public enum ProviderRetry {
    /// Default cap on server-requested delays (`60000` upstream).
    public static let defaultMaxRetryDelayMs = 60_000

    /// Runs ``request``, retrying retryable provider errors up to
    /// `options.maxRetries` times.
    public static func retry<T>(
        _ options: ProviderRetryOptions = .init(),
        _ request: () async throws -> T
    ) async throws -> T {
        let maxRetries = options.maxRetries
        var retriesRemaining = maxRetries

        while true {
            if Task.isCancelled || options.signal?.isCancelled == true { throw CancellationError() }
            do {
                return try await request()
            } catch {
                // A cancelled URLSession task surfaces as a status-less transport
                // error, which the policy would otherwise retry; propagate it.
                if Task.isCancelled || options.signal?.isCancelled == true { throw CancellationError() }
                if retriesRemaining <= 0 { throw error }
                guard let providerError = error as? ProviderHTTPError else { throw error }
                if !isRetryable(providerError) { throw error }
                if let status = providerError.status, options.noRetryStatuses.contains(status) {
                    throw error
                }

                let retryIndex = maxRetries - retriesRemaining
                retriesRemaining -= 1
                let delayMs = try retryDelayMs(
                    for: providerError,
                    retryIndex: retryIndex,
                    maxRetryDelayMs: options.maxRetryDelayMs,
                    baseBackoffMs: options.baseBackoffMs,
                    maxBackoffMs: options.maxBackoffMs,
                    jitterFraction: options.jitterFraction,
                    random: options.random
                )
                try await options.sleep(delayMs)
            }
        }
    }

    /// Whether the pinned SDK policy would retry this provider error.
    static func isRetryable(_ error: ProviderHTTPError) -> Bool {
        if let shouldRetry = error.headers["x-should-retry"] {
            if shouldRetry == "true" { return true }
            if shouldRetry == "false" { return false }
        }
        guard let status = error.status else { return true }
        return status == 408 || status == 409 || status == 429 || status >= 500
    }

    /// Computes the delay before the next attempt (server delay, or jittered
    /// exponential backoff).
    static func retryDelayMs(
        for error: ProviderHTTPError,
        retryIndex: Int,
        maxRetryDelayMs: Int?,
        baseBackoffMs: Int,
        maxBackoffMs: Int,
        jitterFraction: Double,
        random: () -> Double
    ) throws -> Int {
        if let retryAfterMs = error.headers["retry-after-ms"], !retryAfterMs.isEmpty,
           let value = Double(retryAfterMs), value.isFinite {
            return try millis(
                from: validateServerRetryDelayMs(value, maxRetryDelayMs: maxRetryDelayMs, providerErrorMessage: error.message)
            )
        }

        if let retryAfter = error.headers["retry-after"], !retryAfter.isEmpty {
            let seconds = Double(retryAfter)
            let delayMs: Double
            if let seconds {
                delayMs = seconds * 1000
            } else if let date = parseHTTPDate(retryAfter) {
                delayMs = date.timeIntervalSinceNow * 1000
            } else {
                delayMs = .nan
            }
            if delayMs.isFinite {
                return try millis(
                    from: validateServerRetryDelayMs(
                        delayMs,
                        maxRetryDelayMs: maxRetryDelayMs,
                        providerErrorMessage: error.message
                    )
                )
            }
        }

        let exponential = min(Double(baseBackoffMs) * pow(2, Double(retryIndex)), Double(maxBackoffMs))
        return millis(from: exponential * (1 - random() * jitterFraction))
    }

    private static func millis(from value: Double) -> Int {
        Int(value.rounded())
    }

    /// Rejects server-requested delays above the cap (unless the cap is `0`).
    static func validateServerRetryDelayMs(
        _ delayMs: Double,
        maxRetryDelayMs: Int?,
        providerErrorMessage: String
    ) throws -> Double {
        let maxDelayMs = maxRetryDelayMs ?? defaultMaxRetryDelayMs
        if maxDelayMs > 0 && delayMs > Double(maxDelayMs) {
            let requestedSeconds = Int(ceil(delayMs / 1000))
            let maxSeconds = Int(ceil(Double(maxDelayMs) / 1000))
            throw ProviderHTTPError(
                status: nil,
                headers: [:],
                body: nil,
                message: "Server requested \(requestedSeconds)s retry delay (max: \(maxSeconds)s). \(providerErrorMessage)"
            )
        }
        return delayMs
    }

    /// Parses an HTTP-date header value. Tries `DateFormatter` (RFC 1123, RFC
    /// 850, asctime) and then ISO 8601.
    static func parseHTTPDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
        ]
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return ISO8601DateFormatter().date(from: string)
    }

    /// A `Task.sleep` that resolves promptly when ``signal`` is cancelled.
    static func abortableSleep(milliseconds: Int, signal: CancellationSignal?) async throws {
        if signal?.isCancelled == true { throw CancellationError() }
        let nanoseconds = UInt64(max(0, milliseconds)) * 1_000_000

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
            }
            group.addTask {
                try await waitForCancellation(signal)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    /// Suspends until ``signal`` (or task cancellation) fires, throwing
    /// `CancellationError`.
    private static func waitForCancellation(_ signal: CancellationSignal?) async throws {
        if signal?.isCancelled == true { throw CancellationError() }
        let waiter = CancellationWaiter()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiter.store(continuation)
                signal?.onCancel { waiter.cancel() }
            }
        } onCancel: {
            waiter.cancel()
        }
    }
}

/// Lock-protected single-resume continuation box used by ``ProviderRetry``'s
/// abortable sleep. The cancellation handler and the timeout may race.
private final class CancellationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    func store(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}
