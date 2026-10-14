import Foundation
import Testing
@testable import PiAI

@Suite struct ModelCatalogTests {
    // MARK: - Helpers

    private func pricingModel(
        cost: ModelCost,
        reasoning: Bool = false,
        thinkingLevelMap: ThinkingLevelMap? = nil
    ) -> Model {
        Model(
            id: "priced",
            name: "Priced",
            api: "openai-completions",
            provider: "test",
            baseURL: "https://example.com/v1",
            contextWindow: 128_000,
            maxTokens: 4096,
            reasoning: reasoning,
            input: [.text],
            cost: cost,
            thinkingLevelMap: thinkingLevelMap
        )
    }

    private func approx(_ value: Double, _ expected: Double, tolerance: Double = 1e-12) -> Bool {
        abs(value - expected) <= tolerance
    }

    // MARK: - calculateCost

    @Test func calculateCostUsesBaseRates() {
        let model = pricingModel(cost: ModelCost(input: 5, output: 30, cacheRead: 0.5, cacheWrite: 6.25))
        let usage = Usage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000)
        let cost = model.calculateCost(usage: usage)
        #expect(approx(cost.input, 5))
        #expect(approx(cost.output, 30))
        #expect(approx(cost.cacheRead, 0.5))
        #expect(approx(cost.cacheWrite, 6.25))
        #expect(approx(cost.total, 41.75))
    }

    @Test func calculateCostAppliesRequestWideTierAboveThreshold() {
        let model = pricingModel(cost: ModelCost(
            input: 5,
            output: 30,
            cacheRead: 0.5,
            cacheWrite: 6.25,
            tiers: [
                ModelCostTier(
                    inputTokensAbove: 272_000,
                    input: 10,
                    output: 45,
                    cacheRead: 1,
                    cacheWrite: 12.5
                ),
            ]
        ))

        func usage(cacheWrite: Int) -> Usage {
            Usage(input: 200_000, output: 100_000, cacheRead: 72_000, cacheWrite: cacheWrite)
        }

        // 200000 + 72000 + 0 == 272000 is *not* above the threshold.
        let short = model.calculateCost(usage: usage(cacheWrite: 0))
        #expect(approx(short.input, 1))
        #expect(approx(short.output, 3))
        #expect(approx(short.cacheRead, 0.036))
        #expect(approx(short.cacheWrite, 0))

        // 200000 + 72000 + 1 == 273000 crosses the threshold and uses tier rates.
        let long = model.calculateCost(usage: usage(cacheWrite: 1))
        #expect(approx(long.input, 2))
        #expect(approx(long.output, 4.5))
        #expect(approx(long.cacheRead, 0.072))
        #expect(approx(long.cacheWrite, 0.0000125))
    }

    @Test func calculateCostBillsOneHourCacheWriteAtDoubleInputRate() {
        let model = pricingModel(cost: ModelCost(input: 5, output: 30, cacheRead: 0.5, cacheWrite: 6.25))
        let usage = Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 10, cacheWrite1h: 4)
        let cost = model.calculateCost(usage: usage)
        // (6.25 * 6 + 5 * 2 * 4) / 1e6
        #expect(approx(cost.cacheWrite, 0.0000775))
        #expect(approx(cost.total, 0.0000775))
    }

    @Test func applyingCostPopulatesUsage() {
        let model = pricingModel(cost: ModelCost(input: 2))
        let usage = model.applyingCost(to: Usage(input: 1_000_000))
        #expect(approx(usage.cost.input, 2))
        #expect(approx(usage.cost.total, 2))
    }

    // MARK: - Thinking levels

    @Test func nonReasoningModelOnlySupportsOff() {
        let model = pricingModel(cost: .zero, reasoning: false)
        #expect(model.supportedThinkingLevels == [.off])
        #expect(model.clampThinkingLevel(.max) == .off)
        #expect(model.clampThinkingLevel(.medium) == .off)
    }

    @Test func ordinaryReasoningModelExcludesXhighAndMax() {
        let model = pricingModel(cost: .zero, reasoning: true)
        #expect(model.supportedThinkingLevels == [.off, .minimal, .low, .medium, .high])
        #expect(model.clampThinkingLevel(.max) == .high)
    }

    @Test func mappedLevelsOptIntoXhighAndMax() {
        let model = pricingModel(
            cost: .zero,
            reasoning: true,
            thinkingLevelMap: ThinkingLevelMap([.xhigh: .mapped("xhigh"), .max: .mapped("max")])
        )
        #expect(model.supportedThinkingLevels == [.off, .minimal, .low, .medium, .high, .xhigh, .max])
        #expect(model.clampThinkingLevel(.max) == .max)
    }

    @Test func unsupportedLevelClampsToNearestHigher() {
        let model = pricingModel(
            cost: .zero,
            reasoning: true,
            thinkingLevelMap: ThinkingLevelMap([.xhigh: .unsupported, .max: .mapped("max")])
        )
        #expect(model.supportedThinkingLevels == [.off, .minimal, .low, .medium, .high, .max])
        #expect(model.clampThinkingLevel(.xhigh) == .max)
    }

    // MARK: - Codable

    @Test func modelDecodesLegacyJSONWithoutCatalogFields() throws {
        let json = """
        {
          "id": "legacy",
          "name": "Legacy",
          "api": "openai-completions",
          "provider": "openai",
          "baseUrl": "https://api.openai.com/v1",
          "contextWindow": 128000,
          "maxTokens": 4096
        }
        """
        let model = try TestSupport.decode(Model.self, fromJSON: json)
        #expect(model.id == "legacy")
        #expect(model.reasoning == false)
        #expect(model.input == [.text])
        #expect(model.cost == .zero)
        #expect(model.thinkingLevelMap == nil)
        #expect(model.headers == [:])
    }

    @Test func modelRoundTripsCatalogFields() throws {
        let model = pricingModel(
            cost: ModelCost(
                input: 1,
                output: 2,
                cacheRead: 3,
                cacheWrite: 4,
                tiers: [ModelCostTier(inputTokensAbove: 100, input: 5, output: 6, cacheRead: 7, cacheWrite: 8)]
            ),
            reasoning: true,
            thinkingLevelMap: ThinkingLevelMap([
                .minimal: .unsupported,
                .high: .mapped("HIGH"),
                .max: .mapped("max"),
            ])
        )
        let roundTripped = try TestSupport.roundTrip(model)
        #expect(roundTripped == model)
        #expect(roundTripped.cost.tiers?.first?.inputTokensAbove == 100)
    }

    @Test func thinkingLevelMapEncodesNullAsUnsupported() throws {
        let map = ThinkingLevelMap([.minimal: .unsupported, .high: .mapped("HIGH")])
        let value = try TestSupport.encodeToJSONValue(map)
        #expect(value["minimal"].isNull)
        #expect(value["high"] == .string("HIGH"))
        #expect(value["low"].isNull)

        let decoded = try TestSupport.decode(ThinkingLevelMap.self, from: value)
        #expect(decoded == map)
        #expect(decoded[.minimal] == .unsupported)
    }
}
