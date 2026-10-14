import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The response head of a streaming HTTP exchange.
public struct HTTPStreamResponse: Sendable {
    public var statusCode: Int
    /// Response headers with lowercase keys.
    public var headers: [String: String]

    public init(statusCode: Int, headers: [String: String]) {
        self.statusCode = statusCode
        self.headers = headers
    }
}

/// A streaming HTTP response: the status/headers are available immediately and
/// the body is delivered incrementally as raw byte chunks.
public struct HTTPStream: Sendable {
    public var statusCode: Int
    /// Response headers with lowercase keys.
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, any Error>

    public init(statusCode: Int, headers: [String: String], body: AsyncThrowingStream<Data, any Error>) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// An HTTP transport capable of incremental (server-sent events) responses.
///
/// `stream(_:)` resolves once the response head is available. Non-2xx
/// responses throw ``ProviderHTTPError`` (the body is drained first so error
/// messages are preserved); transport failures throw a network
/// ``ProviderHTTPError``. Cancellation is preserved as `CancellationError`.
public protocol StreamingHTTPClient: Sendable {
    func stream(_ request: URLRequest) async throws -> HTTPStream
}

/// The default ``StreamingHTTPClient`` backed by `URLSession.bytes(for:)`.
public struct URLSessionStreamingHTTPClient: StreamingHTTPClient {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Convenience initializer building a `URLSession` from ``configuration``.
    public init(configuration: URLSessionConfiguration) {
        self.session = URLSession(configuration: configuration)
    }

    public func stream(_ request: URLRequest) async throws -> HTTPStream {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as ProviderHTTPError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw ProviderHTTPError.network(message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderHTTPError.network(message: "Invalid HTTP response")
        }
        let headers = URLSessionHTTPClient.lowercasedHeaders(http.allHeaderFields)

        if http.statusCode >= 400 {
            // Drain the error body so the provider error keeps its message.
            var data = Data()
            do {
                for try await byte in bytes { data.append(byte) }
            } catch {
                // A read failure after a known non-2xx status still yields the
                // status-based error below.
            }
            throw ProviderHTTPError.http(status: http.statusCode, headers: headers, body: data)
        }

        let body = Self.makeBody(from: bytes)
        return HTTPStream(statusCode: http.statusCode, headers: headers, body: body)
    }

    /// Bridges `URLSession.AsyncBytes` (one `UInt8` at a time) into buffered
    /// `Data` chunks. The SSE decoder tolerates arbitrary chunk boundaries, so
    /// buffering is purely an efficiency concern.
    private static func makeBody(from bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= 1024 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError {
                    if Task.isCancelled || error.code == .cancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: ProviderHTTPError.network(message: error.localizedDescription))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension URLSessionHTTPClient: StreamingHTTPClient {
    public func stream(_ request: URLRequest) async throws -> HTTPStream {
        try await URLSessionStreamingHTTPClient(session: session).stream(request)
    }
}
