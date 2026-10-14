import Foundation

/// Decodes `text/event-stream` (SSE) bodies into `data:` payloads.
///
/// Framing rules (matching the upstream OpenAI SDK's SSE reader):
/// - Frames are split on `\n` only. A trailing `\r` is tolerated.
/// - Lines that do not start with `data:` (comments, `event:`, `id:`, blank
///   lines) are ignored.
/// - Each `data:` line is dispatched as its own payload, so multi-line SSE
///   events are not merged. OpenAI only ever emits one JSON object per line.
///
/// The decoder is byte-oriented and only decodes complete lines. Because `\n`
/// (0x0A) can never appear inside a UTF-8 multi-byte sequence, this safely
/// handles multi-byte characters split across network chunk boundaries: no
/// bytes are dropped and no partial character is ever decoded.
public struct SSEFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    /// Feeds a byte chunk and returns every complete `data:` payload it unlocks.
    public mutating func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var payloads: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newlineIndex])
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if let payload = Self.payload(from: line) {
                payloads.append(payload)
            }
        }
        return payloads
    }

    /// Flushes a trailing line that was not terminated by `\n` (some servers end
    /// the body without a final newline). Partial UTF-8 is ignored.
    public mutating func finish() -> [String] {
        guard !buffer.isEmpty else { return [] }
        let line = buffer
        buffer.removeAll(keepingCapacity: false)
        return Self.payload(from: line).map { [$0] } ?? []
    }

    private static func payload(from rawLine: Data) -> String? {
        var line = rawLine
        if line.last == 0x0D { line.removeLast() }
        guard !line.isEmpty, let text = String(data: line, encoding: .utf8) else { return nil }
        guard text.hasPrefix("data:") else { return nil }
        var payload = String(text.dropFirst("data:".count))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        return payload
    }
}
