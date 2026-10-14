import Foundation

/// A cancellation signal shared between a caller and an in-flight request.
///
/// The Swift port models upstream `AbortSignal` with a small lock-protected,
/// thread-safe class. Call ``cancel()`` to interrupt an in-flight stream and
/// register handlers with ``onCancel(_:)``.
public final class CancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [@Sendable () -> Void] = []

    public init() {}

    /// Whether ``cancel()`` has been called.
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Cancels the signal and runs every registered handler exactly once.
    public func cancel() {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        let handlers = handlers
        self.handlers.removeAll()
        lock.unlock()
        for handler in handlers { handler() }
    }

    /// Registers a handler invoked on cancellation. Runs immediately when the
    /// signal is already cancelled.
    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        lock.unlock()
    }
}

/// Request context for a chat completion. Mirrors upstream `Context`.
public struct ChatContext: Sendable, Codable, Equatable, Hashable {
    public var systemPrompt: String?
    public var messages: [Message]
    public var tools: [Tool]

    public init(systemPrompt: String? = nil, messages: [Message] = [], tools: [Tool] = []) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }
}

/// Options for a chat completion request. Mirrors the subset of upstream
/// `StreamOptions` needed by the OpenAI-compatible provider.
public struct ChatOptions: Sendable {
    public var apiKey: String
    public var temperature: Double?
    public var maxTokens: Int?
    public var headers: [String: String]
    /// Optional cancellation signal. When cancelled the in-flight stream stops.
    public var signal: CancellationSignal?

    public init(
        apiKey: String = "",
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        headers: [String: String] = [:],
        signal: CancellationSignal? = nil
    ) {
        self.apiKey = apiKey
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.headers = headers
        self.signal = signal
    }
}
