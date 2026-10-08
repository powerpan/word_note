import Foundation
import XCTest
@testable import WordNoteCore

final class DeepSeekChatClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.store.reset()
        super.tearDown()
    }

    func testCompleteSendsFlashWithThinkingDisabled() async throws {
        MockURLProtocol.store.configure(
            statusCode: 200,
            data: Data(
                """
                {"id":"response-1","model":"deepseek-flash","choices":[{"message":{"content":"{\\"input_type\\":\\"word\\",\\"sentence_meaning\\":\\"\\",\\"items\\":[]}"}}]}
                """.utf8
            )
        )
        let client = DeepSeekChatClient(apiKey: "test-key", session: makeSession())

        let completion = try await client.complete(
            messages: [DeepSeekMessage(role: "user", content: "regularization")],
            responseFormat: .jsonObject
        )

        XCTAssertEqual(completion.model, "deepseek-flash")
        let request = try XCTUnwrap(MockURLProtocol.store.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

        let body = try XCTUnwrap(MockURLProtocol.store.lastRequestBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "deepseek-flash")
        XCTAssertEqual((json["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertEqual((json["response_format"] as? [String: Any])?["type"] as? String, "json_object")
    }

    func testCompleteMapsRateLimitResponse() async throws {
        MockURLProtocol.store.configure(statusCode: 429, data: Data("rate limited".utf8))
        let client = DeepSeekChatClient(apiKey: "test-key", session: makeSession())

        do {
            _ = try await client.complete(
                messages: [DeepSeekMessage(role: "user", content: "regularization")],
                responseFormat: .jsonObject
            )
            XCTFail("Expected a rate-limit error.")
        } catch {
            XCTAssertEqual(error as? AIAnalysisError, .rateLimited)
        }
    }

    func testRetryAfterSecondsAndHTTPDateArePreserved() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for (status, header, expected) in [
            (429, "120", now.addingTimeInterval(120)),
            (503, "Tue, 14 Nov 2023 22:14:20 GMT", now.addingTimeInterval(60))
        ] {
            MockURLProtocol.store.configure(statusCode: status, data: Data(), headers: ["Retry-After": header])
            let client = DeepSeekChatClient(apiKey: "test-key", session: makeSession(), now: { now })
            do {
                _ = try await client.complete(messages: [], responseFormat: .jsonObject)
                XCTFail("Expected a provider error")
            } catch let error as AIAnalysisRetryAfterError {
                XCTAssertEqual(error.notBefore, expected)
                XCTAssertEqual(error.failure, status == 429 ? .rateLimited : .server(statusCode: status, summary: "Request rejected"))
            }
        }
    }

    func testRejectedResponseDoesNotExposeProviderBody() async throws {
        for status in [400, 401, 403, 500] {
            MockURLProtocol.store.configure(statusCode: status, data: Data("private-provider-detail".utf8))
            let client = DeepSeekChatClient(apiKey: "test-key", session: makeSession())
            do {
                _ = try await client.complete(messages: [], responseFormat: .jsonObject)
                XCTFail("Expected a provider error")
            } catch {
                XCTAssertEqual(error as? AIAnalysisError, .server(statusCode: status, summary: "Request rejected"))
                XCTAssertFalse(error.localizedDescription.contains("private-provider-detail"))
            }
        }
    }

    func testMalformedEnvelopeIsNotANetworkFailure() async throws {
        MockURLProtocol.store.configure(statusCode: 200, data: Data("not JSON".utf8))
        let client = DeepSeekChatClient(apiKey: "test-key", session: makeSession())
        do {
            _ = try await client.complete(messages: [], responseFormat: .jsonObject)
            XCTFail("Expected an invalid-response error")
        } catch {
            XCTAssertEqual(error as? AIAnalysisError, .invalidResponse)
        }
    }

    func testInvalidRetryAfterDoesNotHideRateLimit() async throws {
        MockURLProtocol.store.configure(statusCode: 429, data: Data(), headers: ["Retry-After": "-5"])
        let client = DeepSeekChatClient(apiKey: "test-key", session: makeSession())
        do {
            _ = try await client.complete(messages: [], responseFormat: .jsonObject)
            XCTFail("Expected a rate-limit error")
        } catch {
            XCTAssertEqual(error as? AIAnalysisError, .rateLimited)
        }
    }

    func testTransportCancellationTimeoutAndNetworkFailureRemainDistinct() async throws {
        for code in [URLError.Code.cancelled, .timedOut, .notConnectedToInternet] {
            MockURLProtocol.store.configure(statusCode: 0, data: Data(), transportError: URLError(code))
            let client = DeepSeekChatClient(apiKey: "test-key", session: makeSession())
            do {
                _ = try await client.complete(messages: [], responseFormat: .jsonObject)
                XCTFail("Expected a transport error")
            } catch {
                switch code {
                case .cancelled: XCTAssertTrue(error is CancellationError)
                case .timedOut: XCTAssertEqual(error as? AIAnalysisError, .timeout)
                default:
                    XCTAssertEqual(error as? AIAnalysisError, .network("The request could not reach the analysis service."))
                }
            }
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockURLProtocol: URLProtocol {
    static let store = MockURLProtocolStore()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.store.response(for: request)
        if let error = stub.transportError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: nil,
                headerFields: stub.headers
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MockURLProtocolStore: @unchecked Sendable {
    private let lock = NSLock()
    private var statusCode = 200
    private var data = Data()
    private var headers: [String: String] = [:]
    private var transportError: URLError?
    private var recordedRequest: URLRequest?
    private var recordedRequestBody: Data?

    var lastRequest: URLRequest? {
        lock.withLock { recordedRequest }
    }

    var lastRequestBody: Data? {
        lock.withLock { recordedRequestBody }
    }

    func configure(statusCode: Int, data: Data, headers: [String: String] = [:], transportError: URLError? = nil) {
        lock.withLock {
            self.statusCode = statusCode
            self.data = data
            self.headers = headers.merging(["Content-Type": "application/json"]) { current, _ in current }
            self.transportError = transportError
            recordedRequest = nil
            recordedRequestBody = nil
        }
    }

    func response(for request: URLRequest) -> (statusCode: Int, data: Data, headers: [String: String], transportError: URLError?) {
        lock.withLock {
            recordedRequest = request
            recordedRequestBody = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
            return (statusCode, data, headers, transportError)
        }
    }

    func reset() {
        configure(statusCode: 200, data: Data())
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}
