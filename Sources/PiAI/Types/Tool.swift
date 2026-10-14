import Foundation

/// Optional provider-side constrained sampling config for a tool.
///
/// Mirrors upstream `false | ConstrainedSamplingConfig`. `disabled` represents
/// the explicit `false` value.
public enum ConstrainedSampling: Sendable, Codable, Equatable, Hashable {
    /// `json_schema` constrained sampling.
    case jsonSchema(strict: Strict)
    /// Grammar constrained sampling with provider-specific variants.
    case grammar(variants: [String: String])
    /// Explicitly disabled (`false` upstream).
    case disabled

    public enum Strict: String, Sendable, Codable, Equatable, Hashable {
        case prefer
        case require
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case strict
        case variants
    }

    private enum Kind: String, Codable {
        case jsonSchema = "json_schema"
        case grammar
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let bool = try? single.decode(Bool.self) {
            _ = bool
            self = .disabled
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .jsonSchema:
            self = .jsonSchema(strict: try container.decode(Strict.self, forKey: .strict))
        case .grammar:
            let variants = try container.decodeIfPresent([String: String].self, forKey: .variants) ?? [:]
            self = .grammar(variants: variants)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .disabled:
            var single = encoder.singleValueContainer()
            try single.encode(false)
        case .jsonSchema(let strict):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.jsonSchema, forKey: .type)
            try container.encode(strict, forKey: .strict)
        case .grammar(let variants):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.grammar, forKey: .type)
            try container.encode(variants, forKey: .variants)
        }
    }
}

/// A tool declaration. Mirrors upstream `Tool`.
public struct Tool: Sendable, Codable, Equatable, Hashable {
    public var name: String
    public var description: String
    public var parameters: JSONSchema
    public var constrainedSampling: ConstrainedSampling?

    public init(
        name: String,
        description: String,
        parameters: JSONSchema,
        constrainedSampling: ConstrainedSampling? = nil
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.constrainedSampling = constrainedSampling
    }
}
