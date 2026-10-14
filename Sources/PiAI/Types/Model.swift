import Foundation

/// A chat model definition.
///
/// Public API per `TASK.md`: `id`, `name`, `api`, `provider`, `baseURL`,
/// `contextWindow`, `maxTokens`, `reasoning`, `headers`. Upstream names the
/// base URL `baseUrl`; the Swift property is `baseURL`, but it still encodes
/// under the upstream `baseUrl` key for catalog compatibility.
public struct Model: Sendable, Codable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var api: String
    public var provider: String
    public var baseURL: String
    public var contextWindow: Int
    public var maxTokens: Int
    public var reasoning: Bool
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
        case headers
    }
}
