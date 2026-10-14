import Foundation
import Testing
@testable import PiAI

@Suite struct ModelTests {
    private func makeModel() -> Model {
        Model(
            id: "gpt-4o",
            name: "GPT-4o",
            api: "openai-completions",
            provider: "openai",
            baseURL: "https://api.openai.com/v1",
            contextWindow: 128_000,
            maxTokens: 16_384,
            reasoning: false,
            headers: ["X-Custom": "1"]
        )
    }

    @Test func roundTripUsesUpstreamBaseUrlKey() throws {
        let model = makeModel()
        let value = try TestSupport.encodeToJSONValue(model)
        #expect(value["baseUrl"] == .string("https://api.openai.com/v1"))
        #expect(value["baseURL"].isNull)
        #expect(value["contextWindow"] == .int(128_000))
        #expect(value["headers"]["X-Custom"] == .string("1"))

        let decoded = try TestSupport.decode(Model.self, from: value)
        #expect(decoded == model)
    }

    @Test func equatableAndHashable() {
        let model = makeModel()
        #expect(model == makeModel())
        #expect(Set([model, makeModel()]).count == 1)
    }
}
