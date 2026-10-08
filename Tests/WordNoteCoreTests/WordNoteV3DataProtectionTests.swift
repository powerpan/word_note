import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3DataProtectionTests: XCTestCase {
    private typealias S = WordNoteV3ServiceTestSupport
    private var root: URL!
    private var queues: [WordNoteV3AnalysisQueue] = []
    private var controllers: [WordNoteDataProtection] = []
    private static let preferences = WordNoteSnapshotPayload.Preferences(appearance: "dark", defaultSource: "book")

    override func setUp() async throws { root = try V3TestSupport.directory() }
    override func tearDown() async throws {
        queues.forEach { $0.suspendForRestore() }
        controllers.forEach { $0.stopAutomaticBackups() }
        queues = []
        controllers = []
        try? FileManager.default.removeItem(at: root)
    }

    func testBackupPreviewAndExportRetainAllElevenEntitiesAndEventMetadata() async throws {
        let h = try await harness()
        let before = try payload(h.session)
        try await h.protection.createBackup()
        let backup = try XCTUnwrap(h.protection.snapshots.first { $0.kind == .manual })
        XCTAssertEqual(backup.schemaVersion, .v3)
        XCTAssertEqual(backup.counts.cards, before.cards.count)
        XCTAssertEqual(backup.counts.sessions, 1)
        XCTAssertEqual(backup.counts.sessionItems, 1)
        let preview = try await h.protection.previewVersionedRestore(id: backup.id)
        XCTAssertEqual(preview.snapshot.payload, .v3(before))
        let url = root.appending(path: "export.json")
        try await h.protection.exportBackup(to: url)
        XCTAssertEqual(try WordNoteSnapshotReader.decode(Data(contentsOf: url)).payload, .v3(before))
        do { _ = try await h.protection.previewRestore(id: backup.id); XCTFail("Legacy previews must not truncate V3") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedSchema) }
        XCTAssertEqual(try payload(h.session), before)
    }

    func testRestoreDiscardsLateCallbackAndResumedGenerationUsesOnlyItsOwnQueue() async throws {
        var continuation: CheckedContinuation<AIAnalysisResult, Error>?
        var calls = 0
        var handlerReturned = false
        let h = try await harness { _ in
            calls += 1
            let result = try await withCheckedThrowingContinuation { continuation = $0 }
            handlerReturned = true
            return result
        }
        defer { continuation?.resume(throwing: CancellationError()) }
        try h.queue.pause()
        let id = try S.inputID(h.queue.enqueue(.init(rawText: "precision", capturedVia: .floatingQuickAdd)))
        XCTAssertEqual(try h.protection.pendingAnalysisCount(), 1)
        try await h.protection.createBackup()
        let preview = try await h.protection.previewVersionedRestore(id: XCTUnwrap(h.protection.snapshots.first { $0.kind == .manual }?.id))
        try h.protection.resumeAnalysis()
        try await waitUntil { calls == 1 }
        let before = try payload(h.session)
        try await h.protection.prepareRestore(preview)
        XCTAssertTrue(h.queue.isSuspended)
        XCTAssertEqual(h.protection.restorePhase, .readyToQuit)
        continuation?.resume(returning: AnalysisTestValues.result())
        continuation = nil
        try await waitUntil { handlerReturned }
        XCTAssertEqual(try payload(h.session), before)
        XCTAssertNil(h.queue.latestAIExplanation)
        XCTAssertThrowsError(try h.queue.enqueue(.init(rawText: "blocked")))
        let next = try h.store.open()
        XCTAssertNotEqual(next.generation, h.session.generation)
        XCTAssertTrue(next.analysisRequiresResume)
        var resumedCalls = 0
        let queue = try WordNoteV3AnalysisQueue(session: next, store: h.store) { _ in
            resumedCalls += 1
            return AnalysisTestValues.result()
        }
        queues.append(queue)
        let protection = WordNoteDataProtection(session: next, store: h.store, vault: h.vault, queue: queue, preferences: { Self.preferences })
        controllers.append(protection)
        _ = try queue.recoverPendingAnalyses()
        XCTAssertEqual(resumedCalls, 0)
        XCTAssertEqual(try protection.pendingAnalysisCount(), 1)
        try protection.resumeAnalysis()
        try await waitUntil { !queue.isBusy }
        XCTAssertEqual(resumedCalls, 1)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try S.record(id, in: next.container).status, .analyzed)
        XCTAssertEqual(try protection.pendingAnalysisCount(), 0)
        XCTAssertEqual(try payload(next).cards, before.cards)
        XCTAssertEqual(try payload(next).eventStates, before.eventStates)
        XCTAssertThrowsError(try h.queue.resumePendingAnalyses())
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.session.storeURL.path))
    }

    func testCancellingPreparedRestoreRetainsPauseUntilExplicitResume() async throws {
        var calls = 0
        let h = try await harness { _ in calls += 1; return AnalysisTestValues.result() }
        try h.queue.pause()
        _ = try h.queue.enqueue(.init(rawText: "precision"))
        try await h.protection.createBackup()
        let preview = try await h.protection.previewVersionedRestore(id: XCTUnwrap(h.protection.snapshots.first { $0.kind == .manual }?.id))
        let before = try payload(h.session)
        try await h.protection.prepareRestore(preview)
        try h.protection.cancelRestore()
        XCTAssertEqual(h.protection.restorePhase, .idle)
        XCTAssertTrue(h.queue.isSuspended)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try payload(h.session), before)
        XCTAssertFalse(WordNoteWriteGate.isBlocked(h.session.container.mainContext))
        XCTAssertFalse(h.session.container.mainContext.autosaveEnabled)
        XCTAssertTrue(try h.store.open().analysisRequiresResume)
        try h.protection.resumeAnalysis()
        try await waitUntil { !h.queue.isBusy }
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(try h.store.open().analysisRequiresResume)
    }

    func testProtectionBackupFailureRetainsDataAndDurablePause() async throws {
        let h = try await harness()
        let before = try payload(h.session)
        let faulty = WordNoteBackupVault(directoryURL: h.vault.directoryURL) {
            if $0 == .snapshotWrite { throw POSIXError(.ENOSPC) }
        }
        let protection = WordNoteDataProtection(session: h.session, store: h.store, vault: faulty, queue: h.queue, preferences: { Self.preferences })
        controllers.append(protection)
        let preview = WordNoteVersionedRestorePreview(snapshot: try WordNoteSnapshotReader.decode(WordNoteSnapshotV3Codec.encode(before, kind: .manual)))
        do { try await protection.prepareRestore(preview); XCTFail("Expected a failed protection backup") }
        catch { XCTAssertEqual(error as? POSIXError, POSIXError(.ENOSPC)) }
        XCTAssertEqual(protection.restorePhase, .idle)
        XCTAssertFalse(WordNoteWriteGate.isBlocked(h.session.container.mainContext))
        XCTAssertTrue(h.queue.isSuspended)
        XCTAssertTrue(try h.store.open().analysisRequiresResume)
        XCTAssertEqual(try payload(h.session), before)
    }

    func testDirtyDraftAndUnspecifiedCSVMembershipsAreRejectedWithoutSaving() async throws {
        let h = try await harness()
        try await h.protection.createBackup()
        let preview = try await h.protection.previewVersionedRestore(id: XCTUnwrap(h.protection.snapshots.first { $0.kind == .manual }?.id))
        let before = try payload(h.session)
        let term = try S.term("quick", in: h.session.container)
        term.chineseMeaning = "Unsaved content"
        do { try await h.protection.createBackup(); XCTFail("Do not commit another editor's draft") }
        catch { XCTAssertEqual(error as? WordNoteV2ContentError, .unsavedChanges) }
        do { try await h.protection.prepareRestore(preview); XCTFail("Do not restore over a dirty context") }
        catch { XCTAssertEqual(error as? WordNoteV2ContentError, .unsavedChanges) }
        XCTAssertEqual(term.chineseMeaning, "Unsaved content")
        XCTAssertTrue(h.session.container.mainContext.hasChanges)
        XCTAssertFalse(WordNoteWriteGate.isBlocked(h.session.container.mainContext))
        h.session.container.mainContext.rollback()
        let csvURL = root.appending(path: "vocabulary.csv")
        do {
            try await h.protection.exportVocabulary(terms: before.content.content.terms, courses: before.content.content.courses, to: csvURL)
            XCTFail("V3 CSV requires frozen membership values")
        } catch { XCTAssertEqual(error as? WordNoteV2ContentError, .invalidValue) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: csvURL.path))
        XCTAssertEqual(try payload(h.session), before)
    }

    func testLegacyRestoreThroughProtectionNeverDowngradesActiveV3Schema() async throws {
        let h = try await harness()
        let legacy = try V3TestSupport.source()
        let created = try await h.vault.create(legacy, kind: .manual)
        let preview = try await h.protection.previewVersionedRestore(id: created.snapshot.id)
        XCTAssertEqual(preview.snapshot.payload.schemaVersion, .v2)
        try await h.protection.prepareRestore(preview)
        let next = try h.store.open()
        XCTAssertEqual(next.schemaVersion, .v3)
        XCTAssertEqual(next.restoreOutcome, .restored)
        XCTAssertTrue(next.analysisRequiresResume)
        XCTAssertEqual(h.protection.snapshots.first { $0.kind == .beforeRestore }?.schemaVersion, .v3)
        let restored = try payload(next)
        XCTAssertEqual(restored.cards.count, legacy.content.terms.count)
        XCTAssertTrue(restored.sessions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.session.storeURL.path))
    }

    private struct Harness {
        let store: WordNoteRestoreStore
        let vault: WordNoteBackupVault
        let session: WordNoteStoreSession
        let queue: WordNoteV3AnalysisQueue
        let protection: WordNoteDataProtection
    }

    private func harness(handler: @escaping WordNoteV3AnalysisQueue.AnalysisHandler = WordNoteTestFixture.analysisResult) async throws -> Harness {
        let store = WordNoteRestoreStore(directoryURL: root.appending(path: "Data"), targetSchema: .v3)
        let vault = WordNoteBackupVault(directoryURL: store.directoryURL.appending(path: "Backups"))
        let session = try await WordNoteStartupCoordinator(store: store, vault: vault, preferences: { Self.preferences }).open()
        if session.preferencesToApply != nil { try store.acknowledgePreferences(for: session.generation) }
        try V3TestSupport.reviewedPayload().populateEmptyStore(session.container.mainContext)
        let queue = try WordNoteV3AnalysisQueue(session: session, store: store, analysisHandler: handler)
        queues.append(queue)
        let protection = WordNoteDataProtection(session: session, store: store, vault: vault, queue: queue, preferences: { Self.preferences })
        controllers.append(protection)
        return Harness(store: store, vault: vault, session: session, queue: queue, protection: protection)
    }

    private func payload(_ session: WordNoteStoreSession) throws -> WordNoteSnapshotV3Payload {
        try .capture(from: session.container.mainContext, preferences: Self.preferences)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw QuickAddQueueWaitError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
