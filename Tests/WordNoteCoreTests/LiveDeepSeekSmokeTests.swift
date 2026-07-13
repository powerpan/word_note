import XCTest
@testable import WordNoteCore

final class LiveDeepSeekSmokeTests: XCTestCase {
    func testLiveDeepSeekSupportsBothLookupDirections() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_DEEPSEEK_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_DEEPSEEK_TESTS=1 to opt into the paid live DeepSeek smoke test.")
        }

        guard let apiKey = DeepSeekAPIKeyResolver.resolve(), !TextNormalizer.isBlank(apiKey)
        else {
            throw XCTSkip("Configure DEEPSEEK_API_KEY to run the live DeepSeek smoke test.")
        }

        let service = AIAnalysisService(client: DeepSeekChatClient(apiKey: apiKey))
        let result = try await service.analyze(
            AIAnalysisRequest(rawText: "latent representation", sourceType: .paper)
        )

        XCTAssertEqual(result.inputType, .phrase)
        XCTAssertTrue(
            result.candidates.contains { TextNormalizer.normalized($0.term).contains("latent representation") },
            "Expected a latent representation candidate, got \(result.candidates.map(\.term))"
        )

        let chineseLookupResult = try await service.analyze(
            AIAnalysisRequest(
                rawText: "過擬合",
                courseName: "CS-50",
                sourceType: .class
            )
        )

        XCTAssertFalse(chineseLookupResult.candidates.isEmpty)
        XCTAssertTrue(
            chineseLookupResult.candidates.allSatisfy {
                LookupDirectionDetector.isEnglishVocabularyTerm($0.term) &&
                    !TextNormalizer.isBlank($0.chineseMeaning ?? "")
            }
        )
        XCTAssertTrue(
            chineseLookupResult.candidates.contains {
                TextNormalizer.normalized($0.term).contains("overfit")
            },
            "Expected an overfitting candidate, got \(chineseLookupResult.candidates.map(\.term))"
        )
    }
}
