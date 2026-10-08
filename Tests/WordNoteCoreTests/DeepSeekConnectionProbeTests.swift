import XCTest
@testable import WordNoteCore

@MainActor
final class DeepSeekConnectionProbeTests: XCTestCase {
    func testFixedPublicRequestReturnsReportedModelWithoutAnalysisInput() async throws {
        let client = ProbeClient(content: "{\"wordnote_connection\":\"ok\"}", model: "test-model")
        let model = try await DeepSeekConnectionProbe(client: client).run()
        XCTAssertEqual(model, "test-model")
        let messages = await client.messages
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "system")
        XCTAssertTrue(messages[0].content.contains("{\"wordnote_connection\":\"ok\"}"))
        XCTAssertEqual(messages[1], .init(role: "user", content: "Test connection."))
        let format = await client.format
        XCTAssertEqual(format, .jsonObject)
        let calls = await client.calls
        XCTAssertEqual(calls, 1)
    }

    func testMalformedNegativeOrOversizedRepliesAreNotSuccessfulConnections() async throws {
        for reply in ["ok", "{}", "{\"wordnote_connection\":true}", "{\"wordnote_connection\":\"no\"}",
                      "```json\n{\"wordnote_connection\":\"ok\"}\n```", String(repeating: " ", count: 1_025)] {
            let client = ProbeClient(content: reply)
            do { _ = try await DeepSeekConnectionProbe(client: client).run(); XCTFail("Expected invalid response") }
            catch { XCTAssertEqual(error as? AIAnalysisError, .invalidResponse) }
        }
    }

    func testUnusableModelLabelsAreRejectedWithoutDisplayingRawProviderText() async throws {
        for model in ["", "  ", String(repeating: "m", count: 129), "model\nprivate-text", "<markup>"] {
            let client = ProbeClient(content: "{\"wordnote_connection\":\"ok\"}", model: model)
            do { _ = try await DeepSeekConnectionProbe(client: client).run(); XCTFail("Expected invalid response") }
            catch { XCTAssertEqual(error as? AIAnalysisError, .invalidResponse) }
        }
    }

    func testProviderFailureIsPropagatedOnceWithoutRetry() async throws {
        let client = ProbeClient(failure: .rateLimited)
        do { _ = try await DeepSeekConnectionProbe(client: client).run(); XCTFail("Expected rate limit") }
        catch { XCTAssertEqual(error as? AIAnalysisError, .rateLimited) }
        let calls = await client.calls
        XCTAssertEqual(calls, 1)
    }

    func testCancelledBeforeStartDoesNotSendARequest() async throws {
        let client = ProbeClient(content: "{\"wordnote_connection\":\"ok\"}")
        let pending = Task { try await DeepSeekConnectionProbe(client: client).run() }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await client.calls
        XCTAssertEqual(calls, 0)
    }

    func testCancellationAfterCompletionCannotBecomeSuccess() async throws {
        let pending = Task { try await DeepSeekConnectionProbe(client: CancellingProbeClient()).run() }
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

private actor ProbeClient: AICompletionClient {
    var calls = 0
    var messages: [DeepSeekMessage] = []
    var format: DeepSeekResponseFormat?
    let result: Result<DeepSeekCompletion, AIAnalysisError>

    init(content: String, model: String = "test-model") {
        result = .success(.init(id: nil, model: model, content: content))
    }
    init(failure: AIAnalysisError) { result = .failure(failure) }

    func complete(messages: [DeepSeekMessage], responseFormat: DeepSeekResponseFormat) async throws -> DeepSeekCompletion {
        calls += 1
        self.messages = messages
        format = responseFormat
        return try result.get()
    }
}

private struct CancellingProbeClient: AICompletionClient {
    func complete(messages: [DeepSeekMessage], responseFormat: DeepSeekResponseFormat) async throws -> DeepSeekCompletion {
        withUnsafeCurrentTask { $0?.cancel() }
        return .init(id: nil, model: "test-model", content: "{\"wordnote_connection\":\"ok\"}")
    }
}
