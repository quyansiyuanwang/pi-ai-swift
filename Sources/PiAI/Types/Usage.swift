import Foundation

/// Token usage and computed cost. Mirrors upstream `Usage`.
public struct Usage: Sendable, Codable, Equatable, Hashable {
    /// Monetary cost in USD.
    public struct Cost: Sendable, Codable, Equatable, Hashable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        public var cacheWrite: Double
        public var total: Double

        public init(
            input: Double = 0,
            output: Double = 0,
            cacheRead: Double = 0,
            cacheWrite: Double = 0,
            total: Double = 0
        ) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.total = total
        }

        public static let zero = Cost()
    }

    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    /// Subset of `cacheWrite` written with 1h retention (Anthropic only).
    public var cacheWrite1h: Int?
    /// Reasoning tokens; a subset of `output` when reported.
    public var reasoning: Int?
    public var totalTokens: Int
    public var cost: Cost

    public init(
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        cacheWrite1h: Int? = nil,
        reasoning: Int? = nil,
        totalTokens: Int = 0,
        cost: Cost = .zero
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.reasoning = reasoning
        self.totalTokens = totalTokens
        self.cost = cost
    }

    public static let zero = Usage()
}
