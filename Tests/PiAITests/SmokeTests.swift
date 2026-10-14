import Testing
@testable import PiAI

@Suite struct SmokeTests {
    @Test func version() {
        #expect(PiAI.version == "0.1.0")
    }
}
