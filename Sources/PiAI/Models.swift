import Foundation

/// Pricing and thinking-level helpers ported from upstream `models.ts`.
///
/// Upstream exports the free functions `calculateCost`, `getSupportedThinkingLevels`
/// and `clampThinkingLevel`. The Swift port exposes them as ``Model`` methods so
/// call sites read naturally (`model.calculateCost(usage:)`).
extension Model {
    /// Computes the USD cost of ``usage`` using this model's pricing catalog.
    ///
    /// Faithful port of upstream `calculateCost`:
    /// - input tokens for tier selection are
    ///   `input + cacheRead + cacheWrite`, excluding output;
    /// - the highest matching `inputTokensAbove` tier applies to the whole
    ///   request and replaces the base rates;
    /// - 1h cache writes (`cacheWrite1h`) are billed at twice the input rate
    ///   (Anthropic), on top of the normal cache-write rate for short writes.
    ///
    /// Upstream mutates `usage.cost` in place and returns it; Swift value
    /// semantics mean the computed ``Usage/Cost`` is returned instead.
    public func calculateCost(usage: Usage) -> Usage.Cost {
        let inputTokens = usage.input + usage.cacheRead + usage.cacheWrite
        var rates = cost.rates
        var matchedThreshold = -1
        for tier in cost.tiers ?? [] {
            if inputTokens > tier.inputTokensAbove && tier.inputTokensAbove > matchedThreshold {
                rates = tier.rates
                matchedThreshold = tier.inputTokensAbove
            }
        }

        let longWrite = usage.cacheWrite1h ?? 0
        let shortWrite = usage.cacheWrite - longWrite

        let input = (rates.input / 1_000_000) * Double(usage.input)
        let output = (rates.output / 1_000_000) * Double(usage.output)
        let cacheRead = (rates.cacheRead / 1_000_000) * Double(usage.cacheRead)
        let cacheWrite = (rates.cacheWrite * Double(shortWrite) + rates.input * 2 * Double(longWrite)) / 1_000_000
        let total = input + output + cacheRead + cacheWrite

        return Usage.Cost(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            total: total
        )
    }

    /// Returns a copy of ``usage`` with ``Usage/cost`` populated by
    /// ``calculateCost(usage:)``.
    public func applyingCost(to usage: Usage) -> Usage {
        var usage = usage
        usage.cost = calculateCost(usage: usage)
        return usage
    }

    /// The thinking levels this model supports, in canonical order.
    ///
    /// Faithful port of upstream `getSupportedThinkingLevels`:
    /// - a non-reasoning model supports only `.off`;
    /// - `xhigh` and `max` are opt-in and require a non-`null` map entry;
    /// - any other level is supported unless its map entry is explicitly
    ///   `null` (``ThinkingLevelMap/Value/unsupported``).
    public var supportedThinkingLevels: [ModelThinkingLevel] {
        guard reasoning else { return [.off] }

        return ModelThinkingLevel.allCases.filter { level in
            switch thinkingLevelMap?[level] {
            case .none:
                return level != .xhigh && level != .max
            case .unsupported:
                return false
            case .mapped:
                return true
            }
        }
    }

    /// Clamps ``level`` to the nearest supported thinking level.
    ///
    /// Faithful port of upstream `clampThinkingLevel`: a supported level is
    /// returned unchanged; otherwise the closest higher level wins, then the
    /// closest lower level, then `.off`.
    public func clampThinkingLevel(_ level: ModelThinkingLevel) -> ModelThinkingLevel {
        let available = supportedThinkingLevels
        if available.contains(level) { return level }

        let levels = ModelThinkingLevel.allCases
        guard let requestedIndex = levels.firstIndex(of: level) else {
            return available.first ?? .off
        }

        for index in requestedIndex..<levels.count where available.contains(levels[index]) {
            return levels[index]
        }
        if requestedIndex > 0 {
            for index in stride(from: requestedIndex - 1, through: 0, by: -1)
            where available.contains(levels[index]) {
                return levels[index]
            }
        }
        return available.first ?? .off
    }
}
