import Foundation

/// The provider contract for streaming chat completions.
///
/// Implemented by `OpenAICompletionsProvider` (M2/M3). Kept as a protocol so
/// additional providers can be added without changing call sites.
public protocol ChatProvider: Sendable {
    func stream(
        model: Model,
        context: ChatContext,
        options: ChatOptions
    ) -> AsyncThrowingStream<AssistantMessageEvent, any Error>
}
