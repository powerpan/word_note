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
        XCTAssertTrue(promptText.contains("English-to-Chinese lookup"))
    }

    func testChineseLookupRequestsEnglishCandidates() async throws {
        let client = MockCompletionClient(
            completion: DeepSeekCompletion(
                id: "mock-id",
                model: "mock-model",
                content: """
                {
                  "input_type": "word",
                  "sentence_meaning": "",
                  "items": [
                    {
                      "term": "overfitting",
                      "term_type": "word",
                      "need_to_learn": true,
                      "importance": "high",
                      "category": "AI/ML",
                      "chinese_meaning": "過擬合；模型過度貼合訓練資料而泛化能力下降。"
                    }
                  ]
                }
                """
            )
        )
        let service = AIAnalysisService(client: client)

        let result = try await service.analyze(AIAnalysisRequest(rawText: "過擬合"))

        XCTAssertEqual(result.candidates.map(\.term), ["overfitting"])
        XCTAssertEqual(result.candidates.first?.chineseMeaning, "過擬合；模型過度貼合訓練資料而泛化能力下降。")
        let promptText = client.lastMessages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(promptText.contains("Chinese-to-English lookup"))
        XCTAssertTrue(promptText.contains("Every items[].term must be an English"))
        XCTAssertTrue(promptText.contains("Lookup direction: Chinese to English"))
    }

    func testChineseLookupRejectsChineseVocabularySubject() async throws {
        let client = MockCompletionClient(
            completion: DeepSeekCompletion(
                id: nil,
                model: "mock-model",
                content: """
                {
                  "input_type": "word",
                  "sentence_meaning": "",
                  "items": [
                    {
                      "term": "過擬合",
                      "term_type": "word",
                      "chinese_meaning": "過擬合"
                    }
                  ]
                }
                """
            )
        )

        do {
            _ = try await AIAnalysisService(client: client).analyze(
                AIAnalysisRequest(rawText: "過擬合")
            )
            XCTFail("Expected a Chinese vocabulary subject to be rejected.")
        } catch let error as AIAnalysisError {
            guard case .schemaMismatch = error else {
                return XCTFail("Expected schema mismatch, got \(error).")
            }
        }
    }

    func testAnalyzeRejectsOverlongInputBeforeCallingClient() async throws {
        let client = MockCompletionClient(
            completion: DeepSeekCompletion(id: nil, model: "unused", content: "{}")
        )
        let service = AIAnalysisService(client: client)
        let request = AIAnalysisRequest(
            rawText: String(repeating: "a", count: AIAnalysisService.maximumInputCharacters + 1)
        )

        do {
            _ = try await service.analyze(request)
            XCTFail("Expected overlong input to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? AIAnalysisError,
                .inputTooLong(maxCharacters: AIAnalysisService.maximumInputCharacters)
            )
        }
        XCTAssertTrue(client.lastMessages.isEmpty)
    }
}

private final class MockCompletionClient: AICompletionClient, @unchecked Sendable {
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
