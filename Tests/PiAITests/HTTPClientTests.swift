import Foundation
import Testing
@testable import PiAI

@Suite struct HTTPClientTests {
    private func makeClient() -> URLSessionHTTPClient {
        URLSessionHTTPClient(configuration: MockURLProtocol.makeConfiguration())
    }

    @Test func returnsResponseForSuccessWithLowercasedHeaders() async throws {
        let endpoint = MockEndpoint()
        endpoint.enqueue(MockURLProtocol.MockResponse(
            statusCode: 200,
            headers: ["X-Request-Id": "abc"],
            body: Data("hello".utf8)
        ))
        let response = try await makeClient().send(
            URLRequest(url: URL(string: endpoint.baseURL)!)
        )
        #expect(response.statusCode == 200)
        #expect(response.body == Data("hello".utf8))
        #expect(response.headers["x-request-id"] == "abc")
        #expect(response.headers["X-Request-Id"] == nil)
    }

    @Test func throwsProviderHTTPErrorForServerError() async {
        let endpoint = MockEndpoint()
        endpoint.enqueue(MockURLProtocol.MockResponse(
            statusCode: 500,
            headers: ["Retry-After": "5"],
            body: Data(#"{"error":{"message":"boom"}}"#.utf8)
        ))
        do {
            _ = try await makeClient().send(URLRequest(url: URL(string: endpoint.baseURL)!))
            Issue.record("expected error")
        } catch let error as ProviderHTTPError {
            #expect(error.status == 500)
            #expect(error.message == "boom")
            #expect(error.headers["retry-after"] == "5")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func throwsNetworkErrorForURLFailure() async {
        let endpoint = MockEndpoint()
        endpoint.enqueue(MockURLProtocol.MockResponse(error: URLError(.cannotConnectToHost)))
        do {
            _ = try await makeClient().send(URLRequest(url: URL(string: endpoint.baseURL)!))
            Issue.record("expected error")
        } catch let error as ProviderHTTPError {
            #expect(error.status == nil)
            #expect(error.body == nil)
            #expect(error.headers.isEmpty)
            let expected = URLError(.cannotConnectToHost).localizedDescription
            #expect(error.message == expected)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
