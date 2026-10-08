import XCTest
@testable import WordNoteCore

@MainActor
final class CaptureFeedbackQueueTests: XCTestCase {
    private typealias Support = WordNoteV2ServiceTestSupport

    func testLocalResultIncludesStableVocabularyTargetAndCaptureMetadata() throws {
        let container = try Support.container()
        let content = try WordNoteV2ContentService(container: container)
        let queue = try makeQueue(content: content) { _ in XCTFail("Local hit must not use AI"); return AnalysisTestValues.result() }
        let presentation = subscribe(to: queue)
        let request = WordNoteCaptureRequest(rawText: "QUICK", intent: .englishToChinese, capturedVia: .floatingQuickAdd)
        let result = try queue.enqueue(request)
        let event = try XCTUnwrap(presentation.event)
        guard case .vocabulary(let id, _, _, _) = result.destination else { return XCTFail("Expected local hit") }
        XCTAssertEqual(event.target, .vocabulary(id))
        XCTAssertEqual(event.captureID, request.captureID)
        XCTAssertEqual(event.capturedVia, .floatingQuickAdd)
        XCTAssertEqual(event.direction, .englishToChinese)
        XCTAssertEqual(event.rows.first?.source, "QUICK")
        XCTAssertEqual(event.preview.candidates.first?.term, "quick")
    }

    func testIdempotentLocalReplayDoesNotRepublishExpiredExplanation() throws {
        let container = try Support.container()
        let queue = try makeQueue(content: WordNoteV2ContentService(container: container)) { _ in AnalysisTestValues.result() }
        let presentation = subscribe(to: queue)
        let request = WordNoteCaptureRequest(rawText: "quick")
        _ = try queue.enqueue(request)
        XCTAssertNotNil(presentation.event)
        presentation.clear()
        XCTAssertTrue(try queue.enqueue(request).isReplay)
        XCTAssertNil(presentation.event)
        _ = try queue.enqueue(.init(rawText: "quick"))
        XCTAssertNotNil(presentation.event)
    }

    func testAnalysisPublishesSavedDirectionAndExactRecordAfterSuccessfulSave() async throws {
        let container = try Support.container(populated: false)
        let queue = try makeQueue(content: WordNoteV2ContentService(container: container)) { request in
            XCTAssertEqual(request.lookupDirection, .chineseToEnglish)
            return AnalysisTestValues.result(candidates: [AnalysisTestValues.candidate("machine learning")])
        }
        let presentation = subscribe(to: queue)
        let request = WordNoteCaptureRequest(rawText: "ML", intent: .chineseToEnglish, capturedVia: .floatingQuickAdd)
        let id = try Support.inputID(queue.enqueue(request))
        try await waitUntil { !queue.isBusy }
        let event = try XCTUnwrap(presentation.event)
        XCTAssertEqual(event.target, .inputRecord(id))
        XCTAssertEqual(event.captureID, request.captureID)
        XCTAssertEqual(event.capturedVia, .floatingQuickAdd)
        XCTAssertEqual(event.direction, .chineseToEnglish)
        XCTAssertEqual(event.rows.first?.source, "machine learning")
        XCTAssertEqual(try Support.record(id, in: container).statusRaw, "analyzed")
    }

    func testResultCompletedWhileHiddenIsNotReplayedToNewlyShownSurface() async throws {
        let container = try Support.container(populated: false)
        let queue = try makeQueue(content: WordNoteV2ContentService(container: container)) { _ in AnalysisTestValues.result() }
        let presentation = subscribe(to: queue)
        presentation.setVisible(false)
        _ = try queue.enqueue(.init(rawText: "precision"))
        try await waitUntil { !queue.isBusy }
        XCTAssertNotNil(queue.latestAIExplanation)
        XCTAssertNil(presentation.event)
        presentation.setVisible(true)
        XCTAssertNil(presentation.event)
        let newWindow = subscribe(to: queue)
        XCTAssertNil(newWindow.event)
    }

    func testMalformedAnalysisDoesNotPublishAFalseSuccess() async throws {
        let container = try Support.container(populated: false)
        let queue = try makeQueue(content: WordNoteV2ContentService(container: container)) { _ in
            AnalysisTestValues.result(candidates: [AnalysisTestValues.candidate("中文主體")])
        }
        let presentation = subscribe(to: queue)
        _ = try queue.enqueue(.init(rawText: "precision"))
        try await waitUntil { !queue.isBusy }
        XCTAssertEqual(queue.failedCount, 1)
        XCTAssertNil(presentation.event)
        XCTAssertTrue(try Support.snapshot(container).content.candidates.isEmpty)
    }

    func testCompletionSaveFailureNeverPublishesUnsavedPreview() async throws {
        let container = try Support.container(populated: false)
        var failSave = false
        let content = try WordNoteV2ContentService(container: container, save: {
            if failSave { throw Support.Failure.save }
            try $0.save()
        })
        let queue = try makeQueue(content: content) { _ in failSave = true; return AnalysisTestValues.result() }
        let presentation = subscribe(to: queue)
        _ = try queue.enqueue(.init(rawText: "precision"))
        try await waitUntil { queue.isSuspended }
        XCTAssertNil(presentation.event)
        XCTAssertTrue(try Support.snapshot(container).content.candidates.isEmpty)
    }

    func testPauseClearsAllVisibleResultsAndLocalLookupStillWorksWithoutResumingAI() throws {
        let container = try Support.container()
        let queue = try makeQueue(content: WordNoteV2ContentService(container: container)) { _ in XCTFail("No AI expected"); return AnalysisTestValues.result() }
        let first = subscribe(to: queue), second = subscribe(to: queue)
        _ = try queue.enqueue(.init(rawText: "quick"))
        XCTAssertNotNil(first.event)
        XCTAssertNotNil(second.event)
        try queue.pause()
        XCTAssertNil(first.event)
        XCTAssertNil(second.event)
        _ = try queue.enqueue(.init(rawText: "quick"))
        XCTAssertTrue(queue.isSuspended)
        XCTAssertNotNil(first.event)
        XCTAssertNotNil(second.event)
    }

    private func subscribe(to queue: WordNoteV2AnalysisQueue) -> CaptureResultPresentation {
        let presentation = CaptureResultPresentation(mode: .main)
        queue.feedback.subscribe(presentation)
        presentation.setVisible(true)
        return presentation
    }

    private func makeQueue(content: WordNoteV2ContentService, handler: @escaping WordNoteV2AnalysisQueue.AnalysisHandler) throws -> WordNoteV2AnalysisQueue {
        try WordNoteV2AnalysisQueue(content: content, analysisHandler: handler, persistPause: {}, authorizeResume: {}, validateSelection: {}, now: { Support.now })
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw WaitError.timeout
    }
    private enum WaitError: Error { case timeout }
}
