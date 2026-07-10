import Foundation
import XCTest
@testable import WordNoteCore

final class DeepSeekChatClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.store.reset()
        super.tearDown()
    }

    func testCompleteSendsV4FlashWithThinkingDisabled() async throws {
        MockURLProtocol.store.configure(
            statusCode: 200,
            data: Data(
                """
                {"id":"response-1","model":"deepseek-v4-flash","choices":[{"message":{"content":"{\\"input_type\\":\\"word\\",\\"sentence_meaning\\":\\"\\",\\"items\\":[]}"}}]}
                """.utf8
            )
        )
        let client = DeepSeekChatClient(apiKey: "test-key", session: makeSession())

        let completion = try await client.complete(
            messages: [DeepSeekMessage(role: "user", content: "regularization")],
            responseFormat: .jsonObject
        )

        XCTAssertEqual(completion.model, "deepseek-v4-flash")
        let request = try XCTUnwrap(MockURLProtocol.store.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

        let body = try XCTUnwrap(MockURLProtocol.store.lastRequestBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "deepseek-v4-flash")
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
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
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
    private var recordedRequest: URLRequest?
    private var recordedRequestBody: Data?

    var lastRequest: URLRequest? {
        lock.withLock { recordedRequest }
    }

    var lastRequestBody: Data? {
        lock.withLock { recordedRequestBody }
    }

    func configure(statusCode: Int, data: Data) {
        lock.withLock {
            self.statusCode = statusCode
            self.data = data
            recordedRequest = nil
            recordedRequestBody = nil
        }
    }

    func response(for request: URLRequest) -> (statusCode: Int, data: Data) {
        lock.withLock {
            recordedRequest = request
            recordedRequestBody = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
            return (statusCode, data)
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
