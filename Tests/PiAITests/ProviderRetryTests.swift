import Foundation
import Testing
@testable import PiAI

/// Thread-safe invocation counter for test closures.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Thread-safe recorder for injected sleep delays.
private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [Int] = []

    func record(_ milliseconds: Int) {
        lock.lock()
        delays.append(milliseconds)
        lock.unlock()
    }

    var recorded: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return delays
    }
}

@Suite struct ProviderRetryTests {
    private func providerError(
        _ status: Int?,
        headers: [String: String] = [:],
        message: String = "Provider error"
    ) -> ProviderHTTPError {
        ProviderHTTPError(status: status, headers: headers, body: nil, message: message)
    }

    @Test func retriesOn429ThenSucceeds() async throws {
        let recorder = SleepRecorder()
        let counter = Counter()
        let result = try await ProviderRetry.retry(
            ProviderRetryOptions(maxRetries: 1, sleep: { recorder.record($0) })
        ) {
            counter.increment()
            if counter.count == 1 {
                throw self.providerError(429, headers: ["retry-after-ms": "1000"], message: "rate limited")
            }
            return "ok"
        }
        #expect(result == "ok")
        #expect(counter.count == 2)
        #expect(recorder.recorded == [1000])
    }

    @Test func retriesOn500() async throws {
        let recorder = SleepRecorder()
        let counter = Counter()
        let result = try await ProviderRetry.retry(
            ProviderRetryOptions(maxRetries: 1, baseBackoffMs: 500, random: { 0 }, sleep: { recorder.record($0) })
        ) {
            counter.increment()
            if counter.count == 1 { throw self.providerError(500) }
            return "ok"
        }
        #expect(result == "ok")
        #expect(counter.count == 2)
        #expect(recorder.recorded == [500])
    }

    @Test func doesNotRetry400() async {
        let counter = Counter()
        do {
            _ = try await ProviderRetry.retry(ProviderRetryOptions(maxRetries: 3, sleep: { _ in })) {
                counter.increment()
                throw self.providerError(400)
            }
            Issue.record("expected error")
        } catch {
            #expect(counter.count == 1)
        }
    }

    @Test func honorsXShouldRetryFalse() async {
        let counter = Counter()
        do {
            _ = try await ProviderRetry.retry(ProviderRetryOptions(maxRetries: 3, sleep: { _ in })) {
                counter.increment()
                throw self.providerError(500, headers: ["x-should-retry": "false"])
            }
            Issue.record("expected error")
        } catch {
            #expect(counter.count == 1)
        }
    }

    @Test func xShouldRetryTrueRetriesNonRetryableStatus() async throws {
        let counter = Counter()
        let result = try await ProviderRetry.retry(ProviderRetryOptions(maxRetries: 1, sleep: { _ in })) {
            counter.increment()
            if counter.count == 1 {
                throw self.providerError(400, headers: ["x-should-retry": "true"])
            }
            return "ok"
        }
        #expect(result == "ok")
        #expect(counter.count == 2)
    }

    @Test func doesNotRetryStatusesInNoRetryStatuses() async {
        let counter = Counter()
        do {
            _ = try await ProviderRetry.retry(
                ProviderRetryOptions(maxRetries: 3, noRetryStatuses: [504], sleep: { _ in })
            ) {
                counter.increment()
                throw self.providerError(504)
            }
            Issue.record("expected error")
        } catch {
            #expect(counter.count == 1)
        }
    }

    @Test func usesRetryAfterMs() async throws {
        let recorder = SleepRecorder()
        let counter = Counter()
        _ = try await ProviderRetry.retry(ProviderRetryOptions(maxRetries: 1, sleep: { recorder.record($0) })) {
            counter.increment()
            if counter.count == 1 {
                throw self.providerError(429, headers: ["retry-after-ms": "1234"])
            }
            return "ok"
        }
        #expect(recorder.recorded == [1234])
    }

    @Test func usesRetryAfterSeconds() async throws {
        let recorder = SleepRecorder()
        let counter = Counter()
        _ = try await ProviderRetry.retry(ProviderRetryOptions(maxRetries: 1, sleep: { recorder.record($0) })) {
            counter.increment()
            if counter.count == 1 {
                throw self.providerError(429, headers: ["retry-after": "2"])
            }
            return "ok"
        }
        #expect(recorder.recorded == [2000])
    }

    @Test func usesRetryAfterHTTPDate() async throws {
        let recorder = SleepRecorder()
        let counter = Counter()
        let future = Date().addingTimeInterval(5)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: future)

        _ = try await ProviderRetry.retry(ProviderRetryOptions(maxRetries: 1, sleep: { recorder.record($0) })) {
            counter.increment()
            if counter.count == 1 {
                throw self.providerError(429, headers: ["retry-after": header])
            }
            return "ok"
        }
        let recorded = try #require(recorder.recorded.first)
        #expect(recorded >= 3000)
        #expect(recorded <= 7000)
    }

    @Test func rejectsServerDelayAboveCap() async {
        let counter = Counter()
        do {
            _ = try await ProviderRetry.retry(
                ProviderRetryOptions(maxRetries: 1, maxRetryDelayMs: 1000, sleep: { _ in })
            ) {
                counter.increment()
                throw self.providerError(429, headers: ["retry-after": "277403"], message: "rate limited")
            }
            Issue.record("expected error")
        } catch let error as ProviderHTTPError {
            #expect(error.message.contains("Server requested 277403s retry delay (max: 1s)"))
            #expect(error.message.contains("rate limited"))
            #expect(counter.count == 1)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func capCanBeDisabled() async throws {
        let recorder = SleepRecorder()
        let counter = Counter()
        _ = try await ProviderRetry.retry(
            ProviderRetryOptions(maxRetries: 1, maxRetryDelayMs: 0, sleep: { recorder.record($0) })
        ) {
            counter.increment()
            if counter.count == 1 {
                throw self.providerError(429, headers: ["retry-after": "2"])
            }
            return "ok"
        }
        #expect(recorder.recorded == [2000])
        #expect(counter.count == 2)
    }

    @Test func exponentialBackoffGrowsAndIsJittered() async throws {
        let recorder = SleepRecorder()
        let counter = Counter()
        _ = try await ProviderRetry.retry(
            ProviderRetryOptions(
                maxRetries: 3,
                baseBackoffMs: 1000,
                maxBackoffMs: 8000,
                jitterFraction: 0.25,
                random: { 0 },
                sleep: { recorder.record($0) }
            )
        ) {
            counter.increment()
            if counter.count <= 3 { throw self.providerError(500) }
            return "ok"
        }
        #expect(recorder.recorded == [1000, 2000, 4000])
        #expect(counter.count == 4)
    }

    @Test func exponentialBackoffRespectsCeiling() async throws {
        let recorder = SleepRecorder()
        let counter = Counter()
        _ = try await ProviderRetry.retry(
            ProviderRetryOptions(
                maxRetries: 2,
                baseBackoffMs: 20_000,
                maxBackoffMs: 8000,
                random: { 0 },
                sleep: { recorder.record($0) }
            )
        ) {
            counter.increment()
            if counter.count <= 2 { throw self.providerError(500) }
            return "ok"
        }
        #expect(recorder.recorded == [8000, 8000])
    }

    @Test func jitterReducesDelay() async throws {
        let recorder = SleepRecorder()
        let counter = Counter()
        _ = try await ProviderRetry.retry(
            ProviderRetryOptions(
                maxRetries: 1,
                baseBackoffMs: 1000,
                jitterFraction: 0.25,
                random: { 1.0 },
                sleep: { recorder.record($0) }
            )
        ) {
            counter.increment()
            if counter.count == 1 { throw self.providerError(500) }
            return "ok"
        }
        #expect(recorder.recorded == [750])
    }

    @Test func alreadyCancelledSignalDoesNotCallRequest() async {
        let signal = CancellationSignal()
        signal.cancel()
        let counter = Counter()
        do {
            _ = try await ProviderRetry.retry(
                ProviderRetryOptions(maxRetries: 3, signal: signal, sleep: { _ in })
            ) {
                counter.increment()
                return "ok"
            }
            Issue.record("expected cancellation")
        } catch {
            #expect(error is CancellationError)
            #expect(counter.count == 0)
        }
    }

    @Test func taskCancellationStopsRetry() async {
        let counter = Counter()
        let task = Task { () -> String in
            try await ProviderRetry.retry(
                ProviderRetryOptions(maxRetries: 5, sleep: { _ in })
            ) {
                counter.increment()
                throw ProviderHTTPError(status: 500, headers: [:], body: nil, message: "boom")
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(counter.count <= 1)
    }

    @Test func nonProviderErrorIsNotRetried() async {
        let counter = Counter()
        do {
            _ = try await ProviderRetry.retry(ProviderRetryOptions(maxRetries: 3, sleep: { _ in })) {
                counter.increment()
                throw CancellationError()
            }
            Issue.record("expected error")
        } catch {
            #expect(counter.count == 1)
        }
    }

    @Test func abortsDuringLongServerDelay() async throws {
        let signal = CancellationSignal()
        let counter = Counter()
        let task = Task { () -> String in
            try await ProviderRetry.retry(
                ProviderRetryOptions(maxRetries: 2, maxRetryDelayMs: 0, signal: signal)
            ) {
                counter.increment()
                throw ProviderHTTPError(
                    status: 429,
                    headers: ["retry-after": "277403"],
                    body: nil,
                    message: "rate limited"
                )
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        signal.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(counter.count == 1)
    }

    @Test func defaultSleepCompletesWithoutSignal() async throws {
        let recorder = SleepRecorder()
        let counter = Counter()
        _ = try await ProviderRetry.retry(
            ProviderRetryOptions(maxRetries: 1, sleep: { recorder.record($0) })
        ) {
            counter.increment()
            if counter.count == 1 {
                throw self.providerError(500, headers: ["retry-after-ms": "1"])
            }
            return "ok"
        }
        #expect(counter.count == 2)
    }

    @Test func httpDateParsingSupportsFormats() {
        #expect(ProviderRetry.parseHTTPDate("Sun, 06 Nov 1994 08:49:37 GMT") != nil)
        #expect(ProviderRetry.parseHTTPDate("Sunday, 06-Nov-94 08:49:37 GMT") != nil)
        #expect(ProviderRetry.parseHTTPDate("Sun Nov  6 08:49:37 1994") != nil)
        #expect(ProviderRetry.parseHTTPDate("not a date") == nil)
    }
}
