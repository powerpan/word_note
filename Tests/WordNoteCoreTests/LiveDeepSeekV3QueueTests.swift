import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class LiveDeepSeekV3QueueTests: XCTestCase {
    func testLiveV3BilingualQueueConfirmationLocalLookupAndIndependentReview() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_DEEPSEEK_V3_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_DEEPSEEK_V3_TESTS=1 to opt into two paid requests using synthetic input.")
        }
        guard let apiKey = DeepSeekAPIKeyResolver.resolve(), !TextNormalizer.isBlank(apiKey) else {
            return XCTFail("Live testing was requested but no DeepSeek API key is configured.")
        }
        typealias S = WordNoteV3ServiceTestSupport
        let container = try S.container(populated: false)
        let content = try WordNoteV3ContentService(container: container)
        var calls = 0
        var models: [String] = []
        let startedAt = ContinuousClock.now
        let queue = try WordNoteV3AnalysisQueue(content: content, analysisHandler: { request in
            guard calls < 2 else { throw AIAnalysisError.invalidResponse }
            calls += 1
            let result = try await AIAnalysisService(client: DeepSeekChatClient(apiKey: apiKey)).analyze(request)
            models.append(result.model)
            return result
        }, persistPause: {}, authorizeResume: {}, validateSelection: {})
        defer { queue.suspendForRestore() }
        let englishID = try S.inputID(queue.enqueue(.init(rawText: "latent representation", sourceType: .paper)))
        let chineseID = try S.inputID(queue.enqueue(.init(rawText: "過擬合", intent: .chineseToEnglish)))
        let deadline = ContinuousClock.now + .seconds(90)
        while queue.isBusy {
            guard ContinuousClock.now < deadline else { throw QuickAddQueueWaitError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(queue.isSuspended)
        XCTAssertEqual(queue.failedCount, 0)
        XCTAssertEqual(calls, 2)
        let analyzed = try S.fullSnapshot(container)
        XCTAssertEqual(analyzed.content.content.inputRecords.count, 2)
        XCTAssertTrue(analyzed.content.content.inputRecords.allSatisfy { $0.statusRaw == "analyzed" })
        XCTAssertTrue(analyzed.content.recordStates.allSatisfy { $0.queueStateRaw == "none" && $0.autoRetryCount == 0 })
        XCTAssertTrue(analyzed.content.content.terms.isEmpty)
        XCTAssertTrue(analyzed.cards.isEmpty)
        let english = try XCTUnwrap(analyzed.content.content.candidates.first {
            $0.inputRecordID == englishID && TextNormalizer.normalized($0.term) == "latent representation"
        })
        let chineseCandidates = analyzed.content.content.candidates.filter { $0.inputRecordID == chineseID }
        XCTAssertTrue(chineseCandidates.allSatisfy {
            LookupDirectionDetector.isEnglishVocabularyTerm($0.term) && !TextNormalizer.isBlank($0.chineseMeaning ?? "")
        })
        let chinese = try XCTUnwrap(chineseCandidates.first { TextNormalizer.normalized($0.term).contains("overfit") })
        for value in [english, chinese] {
            let candidate = try S.candidate(value.term, in: container)
            let record = try S.record(value.inputRecordID, in: container)
            _ = try content.confirmCandidate(candidate.id, expectedRevision: candidate.revision, expectedRecordRevision: record.revision,
                operationID: UUID(), target: .createNew)
        }
        let confirmed = try S.fullSnapshot(container)
        XCTAssertEqual(confirmed.cards.count, 2)
        XCTAssertTrue(confirmed.cards.allSatisfy { $0.mode == .englishToChinese && $0.schedule.phase == .new })
        XCTAssertEqual(Set(confirmed.content.content.terms.map(\.term)), [english.term, chinese.term])
        let repeatRequest = WordNoteCaptureRequest(rawText: "LATENT REPRESENTATION")
        guard case .vocabulary = try queue.enqueue(repeatRequest).destination else { return XCTFail("Expected an exact local match") }
        XCTAssertTrue(try queue.enqueue(repeatRequest).isReplay)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(queue.latestAIExplanation?.candidates.first?.chineseMeaning, english.chineseMeaning)
        let lookedUp = try S.fullSnapshot(container)
        XCTAssertEqual(lookedUp.content.lookupEvents.count, 1)
        XCTAssertTrue(lookedUp.content.content.reviewEvents.isEmpty)
        XCTAssertTrue(lookedUp.content.content.terms.allSatisfy { $0.wrongCount == 0 && $0.duplicateHitCount == 0 && $0.reviewCount == 0 })
        let review = try WordNoteV3ReviewService(container: container)
        _ = try V3SessionTestSupport.introduce(review, at: Date())
        let reviewed = try S.fullSnapshot(container)
        XCTAssertEqual(reviewed.content.content.reviewEvents.count, 1)
        XCTAssertEqual(reviewed.cards.filter { $0.schedule.lastReviewedAt != nil }.count, 1)
        XCTAssertTrue(reviewed.content.content.terms.allSatisfy { $0.reviewCount == 0 && $0.lastReviewedAt == nil && $0.nextReviewAt == nil })
        let restored = try S.container(populated: false)
        try WordNoteSnapshotV3Codec.decode(WordNoteSnapshotV3Codec.encode(reviewed, kind: .manual)).payload.populateEmptyStore(restored.mainContext)
        XCTAssertEqual(try S.fullSnapshot(restored), reviewed)
        print("Live DeepSeek V3 pipeline: models=\(models.joined(separator: ",")); requests=\(calls); elapsed=\(ContinuousClock.now - startedAt)")
    }
}
