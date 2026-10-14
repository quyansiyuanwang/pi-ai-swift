import Foundation
import Testing
@testable import PiAI

@Suite struct SSEFrameDecoderTests {
    @Test func decodesSingleDataLine() {
        var decoder = SSEFrameDecoder()
        let payloads = decoder.append(Data("data: {\"a\":1}\n".utf8))
        #expect(payloads == ["{\"a\":1}"])
    }

    @Test func decodesMultipleLinesInOneChunk() {
        var decoder = SSEFrameDecoder()
        let payloads = decoder.append(Data("data: one\ndata: two\n".utf8))
        #expect(payloads == ["one", "two"])
    }

    @Test func toleratesCarriageReturn() {
        var decoder = SSEFrameDecoder()
        let payloads = decoder.append(Data("data: one\r\ndata: two\r\n".utf8))
        #expect(payloads == ["one", "two"])
    }

    @Test func ignoresNonDataLines() {
        var decoder = SSEFrameDecoder()
        let payloads = decoder.append(Data(": comment\nevent: ping\nid: 3\n\n data: nope\ndata: yes\n".utf8))
        #expect(payloads == ["yes"])
    }

    @Test func buffersIncompleteLineAcrossChunks() {
        var decoder = SSEFrameDecoder()
        #expect(decoder.append(Data("data: hel".utf8)).isEmpty)
        #expect(decoder.append(Data("lo\n".utf8)) == ["hello"])
    }

    @Test func splitsMultibyteUTF8AcrossEveryByteBoundary() {
        // Split a payload containing a multi-byte CJK character and an emoji
        // into single-byte chunks: no bytes may be dropped or mis-decoded.
        let payload = #"{"choices":[{"delta":{"content":"你好🌍"}}]}"#
        let line = Data("data: \(payload)\n".utf8)
        var decoder = SSEFrameDecoder()
        var collected: [String] = []
        for byte in line {
            collected += decoder.append(Data([byte]))
        }
        #expect(collected == [payload])
    }

    @Test func doesNotDecodePartialTrailingCharacter() {
        // A trailing line with a truncated multibyte sequence is ignored.
        var decoder = SSEFrameDecoder()
        let full = Data("data: ok\n".utf8 + [0xE4, 0xBD]) // partial "你"
        #expect(decoder.append(full) == ["ok"])
        #expect(decoder.finish().isEmpty)
    }

    @Test func finishFlushesUnterminatedDataLine() {
        var decoder = SSEFrameDecoder()
        #expect(decoder.append(Data("data: last".utf8)).isEmpty)
        #expect(decoder.finish() == ["last"])
        #expect(decoder.finish().isEmpty)
    }

    @Test func extractsDoneSentinelVerbatim() {
        var decoder = SSEFrameDecoder()
        #expect(decoder.append(Data("data: [DONE]\n".utf8)) == ["[DONE]"])
    }

    @Test func handlesDataWithoutSpace() {
        var decoder = SSEFrameDecoder()
        #expect(decoder.append(Data("data:{\"a\":1}\n".utf8)) == ["{\"a\":1}"])
    }
}

@Suite struct JSONParseTests {
    @Test func parsesPlainJSON() {
        #expect(JSONParse.parse(#"{"a":1}"#) == .object(["a": .int(1)]))
    }

    @Test func repairsRawNewlineInsideString() {
        // A literal newline inside a JSON string is invalid JSON.
        let repaired = JSONParse.repair("{\"a\":\"line1\nline2\"}")
        #expect(repaired == "{\"a\":\"line1\\nline2\"}")
        #expect(JSONParse.parse("{\"a\":\"line1\nline2\"}") == .object(["a": .string("line1\nline2")]))
    }

    @Test func doublesInvalidEscapes() {
        #expect(JSONParse.repair(#"{"a":"\x"}"#) == #"{"a":"\\x"}"#)
    }

    @Test func preservesValidEscapes() {
        #expect(JSONParse.repair(#"{"a":"\n\u00e9"}"#) == #"{"a":"\n\u00e9"}"#)
    }

    @Test func returnsNilForUnrecoverableInput() {
        #expect(JSONParse.parse("not json") == nil)
    }
}
