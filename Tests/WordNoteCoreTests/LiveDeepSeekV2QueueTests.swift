import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class LiveDeepSeekV2QueueTests: XCTestCase {
    func testLiveV2QueuePersistsBothDirectionsAndReusesExactLocalTerm() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_DEEPSEEK_V2_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_DEEPSEEK_V2_TESTS=1 to opt into two paid requests using synthetic input.")
        }
        guard let apiKey = DeepSeekAPIKeyResolver.resolve(), !TextNormalizer.isBlank(apiKey) else {
            XCTFail("Live testing was requested but no DeepSeek API key is configured.")
            return
        }
        let container = try WordNoteV2ServiceTestSupport.container(populated: false)
        let content = try WordNoteV2ContentService(container: container)
        var calls = 0
        var models: [String] = []
        let startedAt = ContinuousClock.now
        let queue = try WordNoteV2AnalysisQueue(
            content: content,
            analysisHandler: { request in
                guard calls < 2 else { throw AIAnalysisError.invalidResponse }
                calls += 1
                let result = try await AIAnalysisService(client: DeepSeekChatClient(apiKey: apiKey)).analyze(request)
                models.append(result.model)
                return result
            }, persistPause: {}, authorizeResume: {}, validateSelection: {}
        )
        defer { queue.suspendForRestore() }
        let englishID = try WordNoteV2ServiceTestSupport.inputID(queue.enqueue(.init(rawText: "latent representation", sourceType: .paper)))
        let chineseID = try WordNoteV2ServiceTestSupport.inputID(queue.enqueue(.init(rawText: "過擬合", intent: .chineseToEnglish)))
        let deadline = ContinuousClock.now + .seconds(90)
        while queue.isBusy {
            guard ContinuousClock.now < deadline else { throw QuickAddQueueWaitError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(queue.isSuspended)
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertEqual(calls, 2)
        let payload = try WordNoteV2ServiceTestSupport.snapshot(container)
        XCTAssertEqual(payload.content.inputRecords.count, 2)
        XCTAssertTrue(payload.content.inputRecords.allSatisfy { $0.statusRaw == "analyzed" })
        XCTAssertTrue(payload.recordStates.allSatisfy { $0.queueStateRaw == "none" && $0.autoRetryCount == 0 })
        XCTAssertTrue(payload.content.terms.isEmpty)
        let english = try XCTUnwrap(payload.content.candidates.first {
            $0.inputRecordID == englishID && TextNormalizer.normalized($0.term) == "latent representation"
        })
        let chinese = payload.content.candidates.filter { $0.inputRecordID == chineseID }
        XCTAssertFalse(chinese.isEmpty)
        XCTAssertTrue(chinese.allSatisfy { LookupDirectionDetector.isEnglishVocabularyTerm($0.term) && !TextNormalizer.isBlank($0.chineseMeaning ?? "") })
        XCTAssertTrue(chinese.contains { TextNormalizer.normalized($0.term).contains("overfit") })
        let candidate = try WordNoteV2ServiceTestSupport.candidate(english.term, in: container)
        let record = try WordNoteV2ServiceTestSupport.record(englishID, in: container)
        _ = try content.confirmCandidate(candidate.id, expectedRevision: candidate.revision, expectedRecordRevision: record.revision,
                                         operationID: UUID(), target: .createNew)
        let repeatLookup = try queue.enqueue(.init(rawText: "LATENT REPRESENTATION"))
        guard case .vocabulary = repeatLookup.destination else { return XCTFail("Expected an exact local match") }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(queue.latestAIExplanation?.candidates.first?.chineseMeaning, english.chineseMeaning)
        XCTAssertEqual(try WordNoteV2ServiceTestSupport.snapshot(container).lookupEvents.count, 1)
        print("Live DeepSeek V2 queue: models=\(models.joined(separator: ",")); requests=\(calls); elapsed=\(ContinuousClock.now - startedAt)")
    }
}
