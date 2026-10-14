import Foundation

/// A model input modality. Mirrors upstream `ModelInputModality`.
public enum ModelInputModality: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case text
    case image
}

/// A pi thinking level, including `off`. Mirrors upstream `ModelThinkingLevel`.
public enum ModelThinkingLevel: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
}

/// Maps pi thinking levels to provider/model-specific values.
///
/// Mirrors upstream `ThinkingLevelMap` (`Partial<Record<ModelThinkingLevel,
/// string | null>>`). A missing level means "use the provider default"; an
/// explicit `null` (``Value/unsupported``) marks the level as unsupported.
public struct ThinkingLevelMap: Sendable, Equatable, Hashable {
    /// One entry in the map.
    public enum Value: Sendable, Equatable, Hashable {
        /// A provider-specific level string.
        case mapped(String)
        /// The level is explicitly unsupported (`null` upstream).
        case unsupported
    }

    private var storage: [ModelThinkingLevel: Value]

    public init(_ storage: [ModelThinkingLevel: Value] = [:]) {
        self.storage = storage
    }

    public subscript(level: ModelThinkingLevel) -> Value? {
        get { storage[level] }
        set { storage[level] = newValue }
    }

    public var isEmpty: Bool { storage.isEmpty }

    /// All explicitly present levels, in canonical order.
    public var levels: [ModelThinkingLevel] {
        ModelThinkingLevel.allCases.filter { storage[$0] != nil }
    }
}

extension ThinkingLevelMap: Codable {
    private struct CodingKey: Swift.CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        init(_ level: ModelThinkingLevel) { self.stringValue = level.rawValue }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKey.self)
        var storage: [ModelThinkingLevel: Value] = [:]
        for key in container.allKeys {
            guard let level = ModelThinkingLevel(rawValue: key.stringValue) else { continue }
            if try container.decodeNil(forKey: key) {
                storage[level] = .unsupported
            } else {
                storage[level] = .mapped(try container.decode(String.self, forKey: key))
            }
        }
        self.init(storage)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKey.self)
        for level in ModelThinkingLevel.allCases {
            guard let value = storage[level] else { continue }
            let key = CodingKey(level)
            switch value {
            case .unsupported:
                try container.encodeNil(forKey: key)
            case .mapped(let string):
                try container.encode(string, forKey: key)
            }
        }
    }
}

/// Per-million-token USD rates. Mirrors upstream `ModelCostRates`.
public struct ModelCostRates: Sendable, Codable, Equatable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public static let zero = ModelCostRates()
}

extension ModelCostRates {
    private enum CodingKeys: String, CodingKey {
        case input, output, cacheRead, cacheWrite
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            input: try container.decodeIfPresent(Double.self, forKey: .input) ?? 0,
            output: try container.decodeIfPresent(Double.self, forKey: .output) ?? 0,
            cacheRead: try container.decodeIfPresent(Double.self, forKey: .cacheRead) ?? 0,
            cacheWrite: try container.decodeIfPresent(Double.self, forKey: .cacheWrite) ?? 0
        )
    }
}

/// A request-wide pricing tier. Mirrors upstream `ModelCostTier`.
public struct ModelCostTier: Sendable, Codable, Equatable, Hashable {
    /// Use this tier when total request input exceeds this token count.
    public var inputTokensAbove: Int
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(
        inputTokensAbove: Int = 0,
        input: Double = 0,
        output: Double = 0,
        cacheRead: Double = 0,
        cacheWrite: Double = 0
    ) {
        self.inputTokensAbove = inputTokensAbove
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var rates: ModelCostRates {
        ModelCostRates(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
    }
}

extension ModelCostTier {
    private enum CodingKeys: String, CodingKey {
        case inputTokensAbove, input, output, cacheRead, cacheWrite
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            inputTokensAbove: try container.decodeIfPresent(Int.self, forKey: .inputTokensAbove) ?? 0,
            input: try container.decodeIfPresent(Double.self, forKey: .input) ?? 0,
            output: try container.decodeIfPresent(Double.self, forKey: .output) ?? 0,
            cacheRead: try container.decodeIfPresent(Double.self, forKey: .cacheRead) ?? 0,
            cacheWrite: try container.decodeIfPresent(Double.self, forKey: .cacheWrite) ?? 0
        )
    }
}

/// A model pricing catalog. Mirrors upstream `ModelCost`: base rates plus
/// optional request-wide `tiers`.
public struct ModelCost: Sendable, Codable, Equatable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    /// Request-wide pricing tiers. The highest matching input threshold applies
    /// to the full request.
    public var tiers: [ModelCostTier]?

    public init(
        input: Double = 0,
        output: Double = 0,
        cacheRead: Double = 0,
        cacheWrite: Double = 0,
        tiers: [ModelCostTier]? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.tiers = tiers
    }

    public var rates: ModelCostRates {
        ModelCostRates(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
    }

    public static let zero = ModelCost()
}

extension ModelCost {
    private enum CodingKeys: String, CodingKey {
        case input, output, cacheRead, cacheWrite, tiers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            input: try container.decodeIfPresent(Double.self, forKey: .input) ?? 0,
            output: try container.decodeIfPresent(Double.self, forKey: .output) ?? 0,
            cacheRead: try container.decodeIfPresent(Double.self, forKey: .cacheRead) ?? 0,
            cacheWrite: try container.decodeIfPresent(Double.self, forKey: .cacheWrite) ?? 0,
            tiers: try container.decodeIfPresent([ModelCostTier].self, forKey: .tiers)
        )
    }
}

/// A chat model definition.
///
/// Public API per `TASK.md`: `id`, `name`, `api`, `provider`, `baseURL`,
/// `contextWindow`, `maxTokens`, `reasoning`, `headers`. Upstream names the
/// base URL `baseUrl`; the Swift property is `baseURL`, but it still encodes
/// under the upstream `baseUrl` key for catalog compatibility.
///
/// The catalog-only fields `input`, `cost` and `thinkingLevelMap` are also
/// modelled so pricing and thinking-level clamping can be ported faithfully.
/// Decoding is backward compatible: every field is optional on the wire and
/// falls back to a sensible default.
public struct Model: Sendable, Codable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var api: String
    public var provider: String
    public var baseURL: String
    public var contextWindow: Int
    public var maxTokens: Int
    public var reasoning: Bool
    /// Input modalities the model accepts. Defaults to `[.text]`.
    public var input: [ModelInputModality]
    /// Pricing catalog. Defaults to all-zero rates.
    public var cost: ModelCost
    /// Optional mapping of pi thinking levels to provider-specific values.
    public var thinkingLevelMap: ThinkingLevelMap?
    public var headers: [String: String]

    public init(
        id: String,
        name: String,
        api: String,
        provider: String,
        baseURL: String,
        contextWindow: Int,
        maxTokens: Int,
        reasoning: Bool = false,
        input: [ModelInputModality] = [.text],
        cost: ModelCost = .zero,
        thinkingLevelMap: ThinkingLevelMap? = nil,
        headers: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.api = api
        self.provider = provider
        self.baseURL = baseURL
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.reasoning = reasoning
        self.input = input
        self.cost = cost
        self.thinkingLevelMap = thinkingLevelMap
        self.headers = headers
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case api
        case provider
        case baseURL = "baseUrl"
        case contextWindow
        case maxTokens
        case reasoning
        case input
        case cost
        case thinkingLevelMap
        case headers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            api: try container.decodeIfPresent(String.self, forKey: .api) ?? "",
            provider: try container.decodeIfPresent(String.self, forKey: .provider) ?? "",
            baseURL: try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "",
            contextWindow: try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 0,
            maxTokens: try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 0,
            reasoning: try container.decodeIfPresent(Bool.self, forKey: .reasoning) ?? false,
            input: try container.decodeIfPresent([ModelInputModality].self, forKey: .input) ?? [.text],
            cost: try container.decodeIfPresent(ModelCost.self, forKey: .cost) ?? .zero,
            thinkingLevelMap: try container.decodeIfPresent(ThinkingLevelMap.self, forKey: .thinkingLevelMap),
            headers: try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        )
    }
}
