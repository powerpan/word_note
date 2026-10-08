import XCTest
@testable import WordNoteCore

final class LiveDeepSeekConnectionTests: XCTestCase {
    func testLiveConnectionWithOneFixedPublicRequest() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_DEEPSEEK_CONNECTION_TEST"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_DEEPSEEK_CONNECTION_TEST=1 to opt into one paid connection probe.")
        }
        guard let key = DeepSeekAPIKeyResolver.resolve() else {
            return XCTFail("Live testing was requested but no credential is configured.")
        }
        let started = ContinuousClock.now
        let model = try await DeepSeekConnectionProbe(client: DeepSeekChatClient(apiKey: key)).run()
        XCTAssertFalse(model.isEmpty)
        print("Live connection probe: requestedModel=\(DeepSeekChatClient.defaultModel); reportedModel=\(model); requests=1; elapsed=\(ContinuousClock.now - started)")
    }
}
