import Foundation

/// Streaming events emitted for an assistant response.
///
/// This is the simplified public protocol defined in `TASK.md`. Upstream emits
/// finer grained `start` / `*_start` / `*_delta` / `*_end` events with a shared
/// `partial` message; the Swift port batches per-block start/end into
/// ``done(_:)`` and keeps only the deltas needed by consumers.
public enum AssistantMessageEvent: Sendable {
    case start
    case textDelta(String)
    case thinkingDelta(String)
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsFragment: String)
    case done(AssistantMessage)
    case error(any Error)
}
