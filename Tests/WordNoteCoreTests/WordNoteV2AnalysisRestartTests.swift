import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2AnalysisRestartTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "analysis-restart-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    func testInterruptedRequestStaysPausedAcrossTwoReopensUntilExplicitResume() async throws {
        let first = try await startup.open()
        let service = try WordNoteV2ContentService(container: first.container)
        let request = WordNoteCaptureRequest(rawText: "precision", sourceType: .paper, note: "frozen source", intent: .chineseToEnglish)
        let result = try service.capture(request)
        let id = try WordNoteV2ServiceTestSupport.inputID(result)
        _ = try service.beginAnalysis(id, expectedRevision: 0)
        var requests: [AIAnalysisRequest] = []
        let firstQueue = try WordNoteV2AnalysisQueue(session: first, store: store) {
            requests.append($0)
            return AnalysisTestValues.result()
        }
        XCTAssertEqual(try firstQueue.recoverPendingAnalyses(), 1)
        XCTAssertTrue(firstQueue.isSuspended)
        XCTAssertTrue(requests.isEmpty)
        let second = try store.open()
        XCTAssertTrue(second.analysisRequiresResume)
        let secondQueue = try WordNoteV2AnalysisQueue(session: second, store: store) {
            requests.append($0)
            return AnalysisTestValues.result()
        }
        XCTAssertEqual(try secondQueue.recoverPendingAnalyses(), 1)
        XCTAssertTrue(secondQueue.isSuspended)
        let third = try store.open()
        XCTAssertTrue(third.analysisRequiresResume)
        let thirdQueue = try WordNoteV2AnalysisQueue(session: third, store: store) {
            requests.append($0)
            return AnalysisTestValues.result()
        }
        XCTAssertEqual(try thirdQueue.resumePendingAnalyses(), 1)
        try await waitUntil { !thirdQueue.isBusy }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.lookupDirection, .chineseToEnglish)
        XCTAssertEqual(requests.first?.sourceType, .paper)
        XCTAssertEqual(requests.first?.userNote, "frozen source")
        let final = try store.open()
        XCTAssertFalse(final.analysisRequiresResume)
        let payload = try WordNoteSnapshotV2Payload.capture(from: final.container.mainContext)
        XCTAssertEqual(payload.content.candidates.count, 1)
        XCTAssertEqual(payload.recordStates[0].captureID, request.captureID)
        XCTAssertEqual(payload.recordStates[0].queueStateRaw, "none")
    }

    func testCancelledRetryDeadlineSurvivesBackupAndReopen() async throws {
        let first = try await startup.open()
        let content = try WordNoteV2ContentService(container: first.container)
        let now = Date()
        let id = try WordNoteV2ServiceTestSupport.inputID(content.capture(.init(rawText: "precision"), at: now))
        let attempt = try content.beginAnalysis(id, expectedRevision: 0, at: now)
        let deadline = now.addingTimeInterval(30)
        try content.failAnalysis(attempt, error: AIAnalysisRetryAfterError(failure: .rateLimited, notBefore: deadline), at: now)
        let record = try WordNoteV2ServiceTestSupport.record(id, in: first.container)
        try content.cancelAnalysis(id, expectedRevision: record.revision, at: now)
        let original = try WordNoteSnapshotV2Payload.capture(from: first.container.mainContext)
        let encoded = try WordNoteSnapshotV2Codec.encode(original, kind: .manual)
        XCTAssertEqual(try WordNoteSnapshotV2Codec.decode(encoded).payload, original)
        let reopened = try store.open()
        let next = try WordNoteV2ContentService(container: reopened.container)
        let job = try XCTUnwrap(next.analysisJobs().first)
        XCTAssertEqual(job.state, .cancelled)
        XCTAssertEqual(job.nextAttemptAt, deadline)
        XCTAssertThrowsError(try next.queueAnalysis(id, expectedRevision: job.revision, at: now))
        _ = try next.queueAnalysis(id, expectedRevision: job.revision, at: deadline)
    }

    func testProductionQueueRejectsPendingRestoreBeforeSending() async throws {
        let session = try await startup.open()
        let content = try WordNoteV2ContentService(container: session.container)
        _ = try content.capture(.init(rawText: "precision"))
        var calls = 0
        let queue = try WordNoteV2AnalysisQueue(session: session, store: store) { _ in
            calls += 1
            return AnalysisTestValues.result()
        }
        let payload = try WordNoteVersionedPayload.capture(from: session.container.mainContext)
        let backup = try await vault.create(payload, kind: .beforeRestore)
        let snapshot = try await vault.readVersionedSnapshot(id: backup.snapshot.id)
        _ = try await store.prepareRestore(snapshot, replacing: session.generation, protectedBy: backup.snapshot)
        XCTAssertThrowsError(try queue.recoverPendingAnalyses()) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .restoreAlreadyPending)
        }
        XCTAssertThrowsError(try queue.enqueue(.init(rawText: "accuracy")))
        XCTAssertEqual(calls, 0)
        let restored = try store.open()
        XCTAssertNotEqual(restored.generation, session.generation)
        XCTAssertThrowsError(try queue.recoverPendingAnalyses()) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .staleGeneration)
        }
        XCTAssertEqual(calls, 0)
    }

    func testInterruptedAutomaticRetryRetainsBudgetAcrossReopen() async throws {
        let session = try await startup.open()
        let first = try WordNoteV2ContentService(container: session.container)
        var time = Date()
        let id = try WordNoteV2ServiceTestSupport.inputID(first.capture(.init(rawText: "precision"), at: time))
        let attempt = try first.beginAnalysis(id, expectedRevision: 0, at: time)
        try first.failAnalysis(attempt, error: AIAnalysisError.timeout, at: time)
        time = time.addingTimeInterval(2)
        let pending = try XCTUnwrap(first.analysisJobs().first)
        _ = try first.beginAnalysis(id, expectedRevision: pending.revision, at: time)
        let interrupted = try WordNoteV2AnalysisQueue(session: session, store: store) { _ in
            XCTFail("Interrupted requests must not replay automatically")
            return AnalysisTestValues.result()
        }
        _ = try interrupted.recoverPendingAnalyses()
        let reopened = try store.open()
        XCTAssertTrue(reopened.analysisRequiresResume)
        let content = try WordNoteV2ContentService(container: reopened.container)
        XCTAssertEqual(try content.analysisJobs().first?.autoRetryCount, 1)
        var calls = 0
        let queue = try WordNoteV2AnalysisQueue(
            content: content, initiallySuspended: reopened.analysisRequiresResume,
            analysisHandler: { _ in calls += 1; throw AIAnalysisError.timeout },
            persistPause: { try self.store.requireAnalysisPause(for: reopened.generation) },
            authorizeResume: { try self.store.authorizeAnalysisResume(for: reopened.generation) },
            validateSelection: {
                guard try !self.store.hasPreparedRestore(for: reopened.generation) else { throw WordNoteRestoreError.restoreAlreadyPending }
            },
            now: { time }, sleep: { time = time.addingTimeInterval($0) }
        )
        _ = try queue.resumePendingAnalyses()
        try await waitUntil { !queue.isBusy }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(queue.failedCount, 1)
        XCTAssertEqual(queue.jobs.first?.autoRetryCount, 2)
    }

    private var store: WordNoteRestoreStore { .init(directoryURL: directory, targetSchema: .v2) }
    private var vault: WordNoteBackupVault { .init(directoryURL: directory.appending(path: "Backups")) }
    private var startup: WordNoteV2StartupCoordinator { .init(store: store, vault: vault, preferences: { .init() }) }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw QuickAddQueueWaitError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
