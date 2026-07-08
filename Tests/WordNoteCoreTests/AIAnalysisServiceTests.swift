import XCTest
@testable import WordNoteCore

final class AIAnalysisServiceTests: XCTestCase {
    func testAnalyzeBuildsPromptAndParsesClientResult() async throws {
        let client = MockCompletionClient(
            completion: DeepSeekCompletion(
                id: "mock-id",
                model: "mock-model",
                content: """
                {
                  "input_type": "word",
                  "sentence_meaning": "",
                  "items": [
                    {"term": "regularization", "term_type": "word", "need_to_learn": true, "importance": "high", "category": "AI/ML"}
                  ]
                }
                """
            )
        )
        let service = AIAnalysisService(client: client)

        let result = try await service.analyze(
            AIAnalysisRequest(rawText: "regularization", sourceType: .class)
        )

        XCTAssertEqual(result.inputType, .word)
        XCTAssertEqual(result.candidates.first?.term, "regularization")
        XCTAssertEqual(client.lastResponseFormat, .jsonObject)
        XCTAssertTrue(client.lastMessages.contains { $0.content.contains("Return a JSON object") })

        let promptText = client.lastMessages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(promptText.contains("general Chinese meaning or meanings"))
        XCTAssertTrue(promptText.contains("AI/CS-specific explanation only when"))
        XCTAssertTrue(promptText.contains("do not force AI-context wording"))
    }
}

private final class MockCompletionClient: AICompletionClient {
    let completion: DeepSeekCompletion
    private(set) var lastMessages: [DeepSeekMessage] = []
    private(set) var lastResponseFormat: DeepSeekResponseFormat?

    init(completion: DeepSeekCompletion) {
        self.completion = completion
    }

    func complete(messages: [DeepSeekMessage], responseFormat: DeepSeekResponseFormat) async throws -> DeepSeekCompletion {
        lastMessages = messages
        lastResponseFormat = responseFormat
        return completion
    }
}
