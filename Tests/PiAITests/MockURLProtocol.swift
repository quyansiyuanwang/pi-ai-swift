import Foundation

/// A `URLProtocol` that serves queued mock responses without a network.
///
/// Swift Testing runs tests in parallel, so global response queues would race.
/// Each test therefore targets a unique mock host (`https://<token>.example.com`)
/// and this protocol keeps a separate response queue/counters per host.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let streamQueue = DispatchQueue(label: "MockURLProtocol.stream")
    private let stopLock = NSLock()
    private var stopped = false

    struct MockResponse: @unchecked Sendable {
        var statusCode: Int
        var headers: [String: String]
        var body: Data?
        var error: Error?
        /// When non-empty, the response is delivered as a streamed body, one
        /// `Data` chunk at a time, before `error`/completion.
        var streamChunks: [Data]
        /// Delay in milliseconds applied between streamed chunks.
        var streamDelayMs: Int
        /// Error delivered after the final streamed chunk (or immediately when
        /// `streamChunks` is empty).
        var streamError: Error?

        init(
            statusCode: Int = 200,
            headers: [String: String] = [:],
            body: Data? = nil,
            error: Error? = nil,
            streamChunks: [Data] = [],
            streamDelayMs: Int = 0,
            streamError: Error? = nil
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.error = error
            self.streamChunks = streamChunks
            self.streamDelayMs = streamDelayMs
            self.streamError = streamError
        }

        static func json(_ json: String, statusCode: Int = 200, headers: [String: String] = [:]) -> MockResponse {
            MockResponse(statusCode: statusCode, headers: headers, body: Data(json.utf8))
        }

        /// A chunked `text/event-stream` response.
        static func stream(
            _ chunks: [Data],
            delayMs: Int = 5,
            error: Error? = nil,
            statusCode: Int = 200,
            headers: [String: String] = ["Content-Type": "text/event-stream"]
        ) -> MockResponse {
            MockResponse(
                statusCode: statusCode,
                headers: headers,
                streamChunks: chunks,
                streamDelayMs: delayMs,
                streamError: error
            )
        }
    }

    /// Per-host response queue and request journal.
    final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [MockResponse] = []
        private var requestCountValue = 0
        private var lastRequestValue: URLRequest?

        func enqueue(_ response: MockResponse) {
            lock.lock()
            responses.append(response)
            lock.unlock()
        }

        func next() -> MockResponse? {
            lock.lock()
            defer { lock.unlock() }
            return responses.isEmpty ? nil : responses.removeFirst()
        }

        func record(_ request: URLRequest) {
            lock.lock()
            requestCountValue += 1
            lastRequestValue = request
            lock.unlock()
        }

        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return requestCountValue
        }

        var lastRequest: URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return lastRequestValue
        }
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var servers: [String: Server] = [:]

    /// Returns (creating if needed) the isolated server for `host`.
    static func server(forHost host: String) -> Server {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let server = servers[host] { return server }
        let server = Server()
        servers[host] = server
        return server
    }

    /// Builds an ephemeral session configuration routing requests through this protocol.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = captureBody(of: request)
        guard let host = request.url?.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let server = Self.server(forHost: host)
        server.record(request)
        guard let response = server.next() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        if !response.streamChunks.isEmpty || response.streamError != nil {
            deliverStream(response, url: url)
            return
        }

        if let http = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        ) {
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        }
        if let body = response.body {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        stopLock.lock()
        stopped = true
        stopLock.unlock()
    }

    /// Delivers a response body incrementally on a private serial queue.
    private func deliverStream(_ response: MockResponse, url: URL) {
        if let http = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        ) {
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        }

        let queue = Self.streamQueue

        let delay = response.streamDelayMs
        let chunks = response.streamChunks
        for (offset, chunk) in chunks.enumerated() {
            queue.asyncAfter(deadline: .now() + .milliseconds(delay * (offset + 1))) { [weak self] in
                guard let self, !self.isStopped else { return }
                self.client?.urlProtocol(self, didLoad: chunk)
            }
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(delay * (chunks.count + 1))) { [weak self] in
            guard let self, !self.isStopped else { return }
            if let error = response.streamError {
                self.client?.urlProtocol(self, didFailWithError: error)
            } else {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    private var isStopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    /// URLSession may move `httpBody` into `httpBodyStream` before handing the
    /// request to a `URLProtocol`; capture whichever form is present.
    private func captureBody(of request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        var request = request
        request.httpBody = Self.readStream(stream)
        return request
    }

    private static func readStream(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// A per-test mock endpoint backed by a unique host.
struct MockEndpoint: Sendable {
    let token: String
    let host: String
    let baseURL: String

    init() {
        let token = UUID().uuidString.lowercased()
        self.token = token
        self.host = "\(token).example.com"
        self.baseURL = "https://\(self.host)/v1"
    }

    var server: MockURLProtocol.Server { MockURLProtocol.server(forHost: host) }

    func enqueue(_ response: MockURLProtocol.MockResponse) {
        server.enqueue(response)
    }

    var requestCount: Int { server.requestCount }

    var lastRequest: URLRequest? { server.lastRequest }
}
