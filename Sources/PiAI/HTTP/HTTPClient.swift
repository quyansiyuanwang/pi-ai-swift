import Foundation

/// A transport-agnostic HTTP response.
public struct HTTPResponse: Sendable {
    public var statusCode: Int
    /// Response headers with lowercase keys.
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// An HTTP transport used by providers.
///
/// Abstracting the transport keeps providers testable without a live network;
/// tests inject a `URLProtocol`-backed ``URLSessionHTTPClient``.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// The default ``HTTPClient`` backed by `URLSession`.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Convenience initializer building a `URLSession` from ``configuration``.
    public init(configuration: URLSessionConfiguration) {
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as ProviderHTTPError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            // URLSession reports task cancellation as `.cancelled`; keep the
            // cooperative-cancellation contract rather than a retryable network error.
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw ProviderHTTPError.network(message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderHTTPError.network(message: "Invalid HTTP response")
        }

        let headers = Self.lowercasedHeaders(http.allHeaderFields)
        if http.statusCode >= 400 {
            throw ProviderHTTPError.http(status: http.statusCode, headers: headers, body: data)
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }

    /// Converts `allHeaderFields` to a lowercase-keyed `[String: String]`.
    /// Keys/values are `Any`, so non-string entries are stringified defensively.
    static func lowercasedHeaders(_ fields: [AnyHashable: Any]) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in fields {
            let name = (key as? String) ?? String(describing: key)
            let text = (value as? String) ?? String(describing: value)
            headers[name.lowercased()] = text
        }
        return headers
    }
}
