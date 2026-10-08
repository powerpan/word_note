import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3AnalysisQueueTests: XCTestCase {
    private typealias Support = WordNoteV3ServiceTestSupport

    func testCapturesRemainNonblockingAndOnlyOneWorkerRuns() async throws {
        let harness = try QueueHarness()
        let probe = AnalysisProbe()
        let queue = try harness.queue(handler: probe.analyze)
        let course = try harness.content.createCourse(courseName: "Fixture Course", at: Support.now)
        let first = try queue.enqueue(.init(rawText: "precision", courseID: course.id, sourceType: .book, note: "first"))
        try await eventually { probe.requests.count == 1 }
        let second = try queue.enqueue(.init(rawText: "準確度", sourceType: .paper, note: "second", intent: .chineseToEnglish))
        XCTAssertNotEqual(try Support.inputID(first), try Support.inputID(second))
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertEqual(queue.queuedCount, 1)
        XCTAssertEqual(try Support.contentSnapshot(harness.container).content.inputRecords.count, 2)
        probe.finish(0)
        try await eventually { probe.requests.count == 2 }
        XCTAssertEqual(probe.requests[0].courseName, "Fixture Course")
        XCTAssertEqual(probe.requests[0].userNote, "first")
        XCTAssertEqual(probe.requests[1].lookupDirection, .chineseToEnglish)
        XCTAssertNil(probe.requests[1].courseName)
        XCTAssertEqual(probe.requests[1].userNote, "second")
        probe.finish(1, result: AnalysisTestValues.result(candidates: [AnalysisTestValues.candidate("accuracy")]))
        try await eventually { !queue.isBusy }
        XCTAssertEqual(probe.maximumActive, 1)
        XCTAssertEqual(queue.latestAIExplanation?.candidates.first?.term, "accuracy")
        XCTAssertEqual(try Support.contentSnapshot(harness.container).content.candidates.count, 2)
    }

    func testCaptureIDReplayDoesNotEnqueueASecondPaidRequest() async throws {
        let harness = try QueueHarness()
        let probe = AnalysisProbe()
        let queue = try harness.queue(handler: probe.analyze)
        let request = WordNoteCaptureRequest(rawText: "precision")
        _ = try queue.enqueue(request)
        try await eventually { probe.requests.count == 1 }
        XCTAssertTrue(try queue.enqueue(request).isReplay)
        XCTAssertEqual(queue.queuedCount, 0)
        probe.finish(0)
        try await eventually { !queue.isBusy }
        XCTAssertTrue(try queue.enqueue(request).isReplay)
        XCTAssertEqual(probe.requests.count, 1)
    }

    func testLocalExactHitUsesExistingMeaningWithoutCallingProvider() async throws {
        let harness = try QueueHarness(populated: true)
        let probe = AnalysisProbe()
        let queue = try harness.queue(handler: probe.analyze)
        let before = try Support.term("quick", in: harness.container).duplicateHitCount
        let request = WordNoteCaptureRequest(rawText: " QUICK ")
        _ = try queue.enqueue(request)
        _ = try queue.enqueue(request)
        XCTAssertEqual(probe.requests.count, 0)
        XCTAssertEqual(queue.latestAIExplanation?.candidates.first?.term, "quick")
        XCTAssertEqual(queue.latestAIExplanation?.candidates.first?.chineseMeaning, try Support.term("quick", in: harness.container).chineseMeaning)
        XCTAssertEqual(try Support.term("quick", in: harness.container).duplicateHitCount, before)
        XCTAssertEqual(try Support.contentSnapshot(harness.container).lookupEvents.count, 1)
    }

    func testNewCaptureWakesBackoffWithoutRetryingDelayedJobEarly() async throws {
        let harness = try QueueHarness()
        let probe = AnalysisProbe()
        let queue = try harness.queue(handler: probe.analyze)
        let first = try queue.enqueue(.init(rawText: "precision"))
        let id = try Support.inputID(first)
        try await eventually { probe.requests.count == 1 }
        probe.fail(0, AIAnalysisRetryAfterError(failure: .rateLimited, notBefore: harness.time.addingTimeInterval(30)))
        try await eventually { harness.sleeps.count == 1 }
        _ = try queue.enqueue(.init(rawText: "accuracy"))
        try await eventually { probe.requests.count == 2 }
        XCTAssertEqual(probe.requests[1].rawText, "accuracy")
        probe.finish(1)
        try await eventually { harness.sleeps.count == 2 }
        XCTAssertEqual(queue.jobs.first { $0.id == id }?.autoRetryCount, 1)
        harness.time = harness.time.addingTimeInterval(30)
        _ = try queue.recoverPendingAnalyses()
        try await eventually { probe.requests.count == 3 }
        XCTAssertEqual(probe.requests[2].rawText, "precision")
        probe.finish(2)
        try await eventually { !queue.isBusy }
        XCTAssertEqual(probe.maximumActive, 1)
    }

    func testAutomaticRetriesAreBoundedAndTerminalFailureDoesNotBlockOthers() async throws {
        let harness = try QueueHarness()
        harness.advanceDuringSleep = true
        var requests: [String] = []
        let queue = try harness.queue { request in
            requests.append(request.rawText)
            if request.rawText == "precision" { throw AIAnalysisError.timeout }
            return AnalysisTestValues.result()
        }
        _ = try queue.enqueue(.init(rawText: "precision"))
        _ = try queue.enqueue(.init(rawText: "accuracy"))
        try await eventually { !queue.isBusy }
        XCTAssertEqual(requests.filter { $0 == "precision" }.count, 3)
        XCTAssertEqual(requests.filter { $0 == "accuracy" }.count, 1)
        XCTAssertEqual(queue.failedCount, 1)
        XCTAssertEqual(harness.sleeps, [2, 4])
        _ = try queue.recoverPendingAnalyses()
        XCTAssertEqual(requests.count, 4)
        XCTAssertFalse(queue.isSuspended)
    }

    func testPermanentAndMalformedFailuresNeverRetryAutomatically() async throws {
        for malformed in [false, true] {
            let harness = try QueueHarness()
            var calls = 0
            let queue = try harness.queue { _ in
                calls += 1
                if malformed { return AnalysisTestValues.result(candidates: [AnalysisTestValues.candidate("中文主體")]) }
                throw AIAnalysisError.missingAPIKey
            }
            _ = try queue.enqueue(.init(rawText: "precision"))
            try await eventually { !queue.isBusy }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(queue.failedCount, 1)
            XCTAssertEqual(queue.jobs.first?.autoRetryCount, 0)
            XCTAssertFalse(queue.isSuspended)
            XCTAssertTrue(harness.sleeps.isEmpty)
        }
    }

    func testCancelActiveIgnoresNoncooperativeLateCallback() async throws {
        let harness = try QueueHarness()
        let probe = AnalysisProbe()
        let queue = try harness.queue(handler: probe.analyze)
        let id = try Support.inputID(queue.enqueue(.init(rawText: "precision")))
        try await eventually { probe.requests.count == 1 }
        let job = try XCTUnwrap(queue.jobs.first { $0.id == id })
        try queue.cancel(id, expectedRevision: job.revision)
        _ = try queue.enqueue(.init(rawText: "accuracy"))
        try await eventually { probe.requests.count == 2 }
        probe.finish(0)
        probe.finish(1, result: AnalysisTestValues.result(candidates: [AnalysisTestValues.candidate("accuracy")]))
        try await eventually { !queue.isBusy }
        let payload = try Support.contentSnapshot(harness.container)
        XCTAssertEqual(payload.content.candidates.map(\.term), ["accuracy"])
        XCTAssertEqual(payload.recordStates.first { $0.id == id }?.queueStateRaw, "cancelled")
        XCTAssertEqual(queue.latestAIExplanation?.rawText, "accuracy")
    }

    func testDeletedActiveRecordIsNotRecreatedAndNextJobContinues() async throws {
        let harness = try QueueHarness()
        let probe = AnalysisProbe()
        let queue = try harness.queue(handler: probe.analyze)
        let id = try Support.inputID(queue.enqueue(.init(rawText: "precision")))
        try await eventually { probe.requests.count == 1 }
        let job = try XCTUnwrap(queue.jobs.first)
        try harness.content.deleteInputRecord(id, expectedRevision: job.revision, at: harness.time)
        _ = try queue.enqueue(.init(rawText: "accuracy"))
        probe.finish(0)
        try await eventually { probe.requests.count == 2 }
        probe.finish(1)
        try await eventually { !queue.isBusy }
        XCTAssertFalse(try Support.contentSnapshot(harness.container).content.inputRecords.contains { $0.id == id })
        XCTAssertFalse(queue.isSuspended)
    }

    func testStorageFailurePausesInsteadOfReissuingPaidRequest() async throws {
        let harness = try QueueHarness()
        let probe = AnalysisProbe()
        let queue = try harness.queue(handler: probe.analyze)
        _ = try queue.enqueue(.init(rawText: "precision"))
        try await eventually { probe.requests.count == 1 }
        harness.failSave = true
        probe.finish(0)
        try await eventually { queue.isSuspended }
        XCTAssertTrue(harness.paused)
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertEqual(queue.jobs.first?.state, .running)
        XCTAssertNil(queue.latestAIExplanation)
        XCTAssertTrue(try Support.contentSnapshot(harness.container).content.candidates.isEmpty)
        harness.failSave = false
        _ = try queue.enqueue(.init(rawText: "accuracy"))
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertEqual(queue.queuedCount, 1)
    }

    func testPauseIsPersistedBeforeInterruptedWorkIsNormalized() throws {
        let harness = try QueueHarness()
        let id = try Support.inputID(harness.content.capture(.init(rawText: "precision"), at: harness.time))
        _ = try harness.content.beginAnalysis(id, expectedRevision: 0, at: harness.time)
        let probe = AnalysisProbe()
        let queue = try harness.queue(handler: probe.analyze)
        harness.failPause = true
        XCTAssertThrowsError(try queue.recoverPendingAnalyses())
        XCTAssertTrue(queue.isSuspended)
        XCTAssertEqual(try Support.record(id, in: harness.container).queueStateRaw, "running")
        XCTAssertEqual(probe.requests.count, 0)
        harness.failPause = false
        XCTAssertEqual(try queue.recoverPendingAnalyses(), 1)
        XCTAssertEqual(harness.stateWhenPausing, "running")
        XCTAssertTrue(harness.paused)
        XCTAssertEqual(try Support.record(id, in: harness.container).queueStateRaw, "queued")
        XCTAssertEqual(probe.requests.count, 0)
    }

    func testFailedResumeAuthorizationKeepsWorkPaused() throws {
        let harness = try QueueHarness()
        harness.paused = true
        harness.failResume = true
        let probe = AnalysisProbe()
        let queue = try harness.queue(handler: probe.analyze)
        _ = try queue.enqueue(.init(rawText: "precision"))
        XCTAssertThrowsError(try queue.resumePendingAnalyses())
        XCTAssertTrue(queue.isSuspended)
        XCTAssertTrue(harness.paused)
        XCTAssertEqual(queue.queuedCount, 1)
        XCTAssertEqual(probe.requests.count, 0)
    }

    func testChangedStoreSelectionRejectsLateCallback() async throws {
        let harness = try QueueHarness()
        let probe = AnalysisProbe()
        let queue = try harness.queue(handler: probe.analyze)
        _ = try queue.enqueue(.init(rawText: "precision"))
        try await eventually { probe.requests.count == 1 }
        let before = try Support.contentSnapshot(harness.container)
        harness.validSelection = false
        probe.finish(0)
        try await eventually { queue.isSuspended }
        XCTAssertEqual(try Support.contentSnapshot(harness.container), before)
        XCTAssertNil(queue.latestAIExplanation)
        XCTAssertThrowsError(try queue.enqueue(.init(rawText: "accuracy")))
        XCTAssertThrowsError(try queue.resumePendingAnalyses())
    }

    func testRestoreSuspensionClearsPreviewAndDiscardsLateResult() async throws {
        let harness = try QueueHarness()
        let probe = AnalysisProbe()
        let queue = try harness.queue(handler: probe.analyze)
        _ = try queue.enqueue(.init(rawText: "precision"))
        try await eventually { probe.requests.count == 1 }
        let ticket = try WordNoteWriteGate.beginRestore(harness.container.mainContext)
        queue.suspendForRestore()
        probe.finish(0)
        try WordNoteWriteGate.endRestore(harness.container.mainContext, ticket: ticket)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(queue.isSuspended)
        XCTAssertNil(queue.latestAIExplanation)
        XCTAssertTrue(try Support.contentSnapshot(harness.container).content.candidates.isEmpty)
        XCTAssertEqual(probe.requests.count, 1)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now > deadline { throw QueueHarness.Failure.wait }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

@MainActor
private final class QueueHarness {
    enum Failure: Error { case save, pause, resume, wait }
    let container: ModelContainer
    var content: WordNoteV3ContentService!
    var time = WordNoteV3ServiceTestSupport.now
    var paused = false
    var failSave = false
    var failPause = false
    var failResume = false
    var validSelection = true
    var stateWhenPausing: String?
    var sleeps: [TimeInterval] = []
    var advanceDuringSleep = false

    init(populated: Bool = false) throws {
        container = try WordNoteV3ServiceTestSupport.container(populated: populated)
        content = try WordNoteV3ContentService(container: container, beforeSave: { [unowned self] _ in
            if self.failSave { throw Failure.save }
        })
    }

    func queue(handler: @escaping WordNoteV3AnalysisQueue.AnalysisHandler) throws -> WordNoteV3AnalysisQueue {
        try WordNoteV3AnalysisQueue(
            content: content, initiallySuspended: paused, analysisHandler: handler,
            persistPause: { [self] in
                if failPause { throw Failure.pause }
                stateWhenPausing = try content.analysisJobs().first?.state.rawValue
                paused = true
            },
            authorizeResume: { [self] in
                if failResume { throw Failure.resume }
                paused = false
            },
            validateSelection: { [self] in
                if !validSelection { throw WordNoteRestoreError.staleGeneration }
            },
            now: { [self] in time },
            sleep: { [self] delay in
                sleeps.append(delay)
                if advanceDuringSleep { time = time.addingTimeInterval(delay) }
                else { try await Task.sleep(for: .seconds(3_600)) }
            }
        )
    }
}

@MainActor
private final class AnalysisProbe {
    private var continuations: [CheckedContinuation<AIAnalysisResult, Error>?] = []
    private var active = 0
    var maximumActive = 0
    var requests: [AIAnalysisRequest] = []

    func analyze(_ request: AIAnalysisRequest) async throws -> AIAnalysisResult {
        requests.append(request)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func finish(_ index: Int, result: AIAnalysisResult = AnalysisTestValues.result()) {
        let continuation = continuations[index]
        continuations[index] = nil
        continuation?.resume(returning: result)
    }

    func fail(_ index: Int, _ error: Error) {
        let continuation = continuations[index]
        continuations[index] = nil
        continuation?.resume(throwing: error)
    }
}
