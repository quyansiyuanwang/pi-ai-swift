import Foundation

/// The provider contract for non-streaming chat completions.
///
/// Streaming is covered by ``ChatProvider`` (M3); this protocol is the
/// synchronous subset used by ``OpenAICompletionsProvider``.
public protocol ChatCompleting: Sendable {
    func complete(model: Model, context: ChatContext, options: ChatOptions) async throws -> AssistantMessage
}
