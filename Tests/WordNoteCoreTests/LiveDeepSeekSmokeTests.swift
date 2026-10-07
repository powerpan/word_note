import XCTest
import SwiftData
@testable import WordNoteCore

@MainActor
final class LiveDeepSeekSmokeTests: XCTestCase {
    func testLiveDeepSeekSupportsBothLookupDirections() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_DEEPSEEK_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_DEEPSEEK_TESTS=1 to opt into the paid live DeepSeek smoke test.")
        }

        guard let apiKey = DeepSeekAPIKeyResolver.resolve(), !TextNormalizer.isBlank(apiKey)
        else {
            XCTFail("Live testing was requested but no DeepSeek API key is configured.")
            return
        }

        let startedAt = ContinuousClock.now
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        defer { withExtendedLifetime(container) {} }
        let inputService = InputRecordService(modelContext: container.mainContext)
        let englishRecord = try inputService.createDraft(rawText: "latent representation", courseID: nil, sourceType: .paper, note: nil)
        let englishOutcome = try await inputService.analyze(
            englishRecord, request: AIAnalysisRequest(rawText: "latent representation", sourceType: .paper),
            using: { try await AIAnalysisService(client: DeepSeekChatClient(apiKey: apiKey)).analyze($0) }
        )
        let result = englishOutcome.analysis

        XCTAssertEqual(result.inputType, .phrase)
        XCTAssertTrue(
            result.candidates.contains { TextNormalizer.normalized($0.term).contains("latent representation") },
            "Expected a latent representation candidate, got \(result.candidates.map(\.term))"
        )

        let chineseRecord = try inputService.createDraft(rawText: "過擬合", courseID: nil, sourceType: .class, note: nil)
        let chineseOutcome = try await inputService.analyze(
            chineseRecord, request: AIAnalysisRequest(
                rawText: "過擬合",
                courseName: "CS-50",
                sourceType: .class
            ), using: { try await AIAnalysisService(client: DeepSeekChatClient(apiKey: apiKey)).analyze($0) }
        )
        let chineseLookupResult = chineseOutcome.analysis

        XCTAssertFalse(chineseLookupResult.candidates.isEmpty)
        XCTAssertTrue(
            chineseLookupResult.candidates.allSatisfy {
                LookupDirectionDetector.isEnglishVocabularyTerm($0.term) &&
                    !TextNormalizer.isBlank($0.chineseMeaning ?? "")
            }
        )
        XCTAssertEqual(englishRecord.status, .analyzed)
        XCTAssertEqual(chineseRecord.status, .analyzed)
        XCTAssertGreaterThan(englishOutcome.candidateCount, 0)
        XCTAssertGreaterThan(chineseOutcome.candidateCount, 0)
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<CandidateTermModel>()),
            englishOutcome.candidateCount + chineseOutcome.candidateCount
        )
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<TermModel>()), 0)
        XCTAssertTrue(
            chineseLookupResult.candidates.contains {
                TextNormalizer.normalized($0.term).contains("overfit")
            },
            "Expected an overfitting candidate, got \(chineseLookupResult.candidates.map(\.term))"
        )
        print("Live DeepSeek: models=\(result.model),\(chineseLookupResult.model); requests=2; elapsed=\(ContinuousClock.now - startedAt)")
    }
}
