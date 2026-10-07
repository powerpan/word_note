import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2DataProtectionTests: XCTestCase {
    private var root: URL!
    private var controllers: [WordNoteDataProtection] = []
    private var queues: [WordNoteV2AnalysisQueue] = []
    private typealias Support = WordNoteV2ServiceTestSupport

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "v2-app-protection-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        queues.forEach { $0.suspendForRestore() }
        controllers.forEach { $0.stopAutomaticBackups() }
        controllers = []
        queues = []
        try? FileManager.default.removeItem(at: root)
    }

    func testV2BackupPreviewAndExportKeepAllEightEntitiesAndPreferences() async throws {
        let h = try await harness()
        let service = try WordNoteV2ContentService(container: h.session.container)
        _ = try service.capture(.init(rawText: "quick", capturedVia: .floatingQuickAdd))
        try await h.controller.createBackup()
        let backup = try XCTUnwrap(h.controller.snapshots.first { $0.kind == .manual })
        let before = try payload(h)
        let preview = try await h.controller.previewVersionedRestore(id: backup.id)
        XCTAssertEqual(preview.snapshot.payload, .v2(before))
        XCTAssertEqual(backup.counts.occurrences, 1)
        XCTAssertEqual(backup.counts.lookupEvents, 1)
        XCTAssertEqual(backup.counts.courseLinks, 4)
        let url = root.appending(path: "export.json")
        try await h.controller.exportBackup(to: url)
        XCTAssertEqual(try WordNoteSnapshotReader.decode(Data(contentsOf: url)).payload, .v2(before))
        do { _ = try await h.controller.previewRestore(id: backup.id); XCTFail("Legacy preview must not downgrade V2.") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedSchema) }
    }

    func testV2CSVRequiresFrozenMembershipsAndDoesNotFallBackToLegacyCourse() async throws {
        let h = try await harness()
        let before = try payload(h)
        let term = try XCTUnwrap(before.content.terms.first)
        let ids = Set(before.content.courses.map(\.id))
        let url = root.appending(path: "terms.csv")
        do {
            try await h.controller.exportVocabulary(terms: [term], courses: before.content.courses, to: url)
            XCTFail("V2 export needs explicit membership values.")
        } catch { XCTAssertEqual(error as? WordNoteV2ContentError, .invalidValue) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try await h.controller.exportVocabulary(terms: [term], courses: before.content.courses, courseMemberships: [term.id: ids], to: url)
        let csv = try String(contentsOf: url, encoding: .utf8)
        for course in before.content.courses { XCTAssertTrue(csv.contains(course.courseName)) }
        let empty = VocabularyCSVExporter.export(terms: [term], courses: before.content.courses, courseMemberships: [:])
        XCTAssertFalse(String(decoding: empty, as: UTF8.self).contains(before.content.courses[0].courseName))
        XCTAssertEqual(try payload(h), before)
    }

    func testDirtyV2ContextIsNotSavedByBackupOrRestore() async throws {
        let h = try await harness()
        try await h.controller.createBackup()
        let preview = try await h.controller.previewVersionedRestore(id: XCTUnwrap(h.controller.snapshots.first?.id))
        let term = try Support.term("quick", in: h.session.container)
        term.chineseMeaning = "Unsaved direct edit"
        do { try await h.controller.createBackup(); XCTFail("Must not save an unrelated edit.") }
        catch { XCTAssertEqual(error as? WordNoteV2ContentError, .unsavedChanges) }
        do { try await h.controller.prepareRestore(preview); XCTFail("Must reject dirty context before pausing.") }
        catch { XCTAssertEqual(error as? WordNoteV2ContentError, .unsavedChanges) }
        XCTAssertFalse(WordNoteWriteGate.isBlocked(h.session.container.mainContext))
        XCTAssertEqual(h.controller.errorMessage, WordNoteV2ContentError.unsavedChanges.localizedDescription)
        XCTAssertEqual(h.controller.restorePhase, .idle)
        XCTAssertTrue(h.session.container.mainContext.hasChanges)
        h.session.container.mainContext.rollback()
        XCTAssertNotEqual(term.chineseMeaning, "Unsaved direct edit")
    }

    func testV2RestorePrepareCancelAndActivateUseSameGenerationJournal() async throws {
        let h = try await harness()
        try await h.controller.createBackup()
        let preview = try await h.controller.previewVersionedRestore(id: XCTUnwrap(h.controller.snapshots.first { $0.kind == .manual }?.id))
        let before = try payload(h)
        try await h.controller.prepareRestore(preview)
        XCTAssertEqual(h.controller.restorePhase, .readyToQuit)
        XCTAssertTrue(WordNoteWriteGate.isBlocked(h.session.container.mainContext))
        XCTAssertTrue(h.queue.isSuspended)
        XCTAssertThrowsError(try h.queue.enqueue(.init(rawText: "blocked request")))
        XCTAssertEqual(h.controller.snapshots.first { $0.kind == .beforeRestore }?.schemaVersion, .v2)
        try h.controller.cancelRestore()
        XCTAssertFalse(WordNoteWriteGate.isBlocked(h.session.container.mainContext))
        XCTAssertFalse(h.session.container.mainContext.autosaveEnabled)
        XCTAssertEqual(try payload(h), before)
        try await h.controller.prepareRestore(preview)
        let next = try await WordNoteV2StartupCoordinator(store: h.store, vault: h.vault, preferences: { .init() }).open()
        XCTAssertEqual(next.restoreOutcome, .restored)
        XCTAssertNotEqual(next.generation, h.session.generation)
        XCTAssertEqual(try WordNoteSnapshotV2Payload.capture(from: next.container.mainContext, preferences: before.content.preferences), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.session.storeURL.path))
    }

    func testRestoreOfLegacyBackupStaysV2AndRetainsProtection() async throws {
        let h = try await harness()
        let oldBackup = try XCTUnwrap(h.controller.snapshots.first { $0.kind == .beforeMigration })
        let preview = try await h.controller.previewVersionedRestore(id: oldBackup.id)
        XCTAssertEqual(preview.snapshot.payload.schemaVersion, .v1)
        try await h.controller.prepareRestore(preview)
        let next = try h.store.open()
        XCTAssertEqual(next.schemaVersion, .v2)
        XCTAssertEqual(next.restoreOutcome, .restored)
        XCTAssertEqual(h.controller.snapshots.first { $0.kind == .beforeRestore }?.schemaVersion, .v2)
    }

    func testRestoredPendingRequestsRemainPausedUntilOneSharedQueueIsResumed() async throws {
        let h = try await harness()
        try h.queue.pause()
        _ = try h.queue.enqueue(.init(rawText: "bounded buffer", capturedVia: .mainQuickAdd))
        _ = try h.queue.enqueue(.init(rawText: "過擬合", capturedVia: .floatingQuickAdd))
        XCTAssertEqual(try h.controller.pendingAnalysisCount(), 2)
        try await h.controller.createBackup()
        let preview = try await h.controller.previewVersionedRestore(id: XCTUnwrap(h.controller.snapshots.first { $0.kind == .manual }?.id))
        try await h.controller.prepareRestore(preview)
        let next = try h.store.open()
        var calls = 0
        let queue = try WordNoteV2AnalysisQueue(session: next, store: h.store) { request in
            calls += 1
            return WordNoteTestFixture.analysisResult(for: request)
        }
        queues.append(queue)
        let controller = WordNoteDataProtection(session: next, store: h.store, vault: h.vault, queue: queue, preferences: { .init() })
        controllers.append(controller)
        _ = try queue.recoverPendingAnalyses()
        await Task.yield()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try controller.pendingAnalysisCount(), 2)
        try controller.resumeAnalysis()
        try await drain(queue)
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(queue.isSuspended)
        XCTAssertEqual(try controller.pendingAnalysisCount(), 0)
        XCTAssertFalse(try h.store.open().analysisRequiresResume)
        XCTAssertNoThrow(try WordNoteSnapshotV2Payload.capture(from: next.container.mainContext))
    }

    func testSharedCaptureConfirmRepeatBackupFlowUsesNoAdditionalRequestForExactHit() async throws {
        let h = try await harness()
        try h.controller.resumeAnalysis()
        let capture = try h.queue.enqueue(.init(rawText: "bounded buffer", capturedVia: .floatingQuickAdd))
        try await drain(h.queue)
        let id = try Support.inputID(capture)
        let record = try Support.record(id, in: h.session.container)
        let candidate = try Support.candidate("bounded buffer", in: h.session.container)
        let service = try WordNoteV2ContentService(container: h.session.container)
        let saved = try service.confirmNewCandidates([.init(id: candidate.id, revision: candidate.revision, recordID: id, recordRevision: record.revision)])
        let result = try h.queue.enqueue(.init(rawText: "BOUNDED BUFFER", capturedVia: .mainQuickAdd))
        guard case .vocabulary(let termID, _, _, _) = result.destination else { return XCTFail("Expected a local exact hit.") }
        XCTAssertEqual(termID, saved[0].id)
        XCTAssertEqual(h.queue.queuedCount, 0)
        XCTAssertEqual(h.queue.latestAIExplanation?.candidates.first?.term, "bounded buffer")
        try await h.controller.createBackup()
        let full = try payload(h)
        XCTAssertEqual(full.occurrences.filter { $0.termID == termID }.count, 2)
        XCTAssertEqual(full.lookupEvents.filter { $0.termID == termID }.count, 1)
        XCTAssertEqual(Set(full.occurrences.filter { $0.termID == termID }.map(\.capturedViaRaw)), ["mainQuickAdd", "floatingQuickAdd"])
    }

    func testBackupFailureReleasesGateButDoesNotResumePaidRequests() async throws {
        let h = try await harness()
        let before = try payload(h)
        let faulty = WordNoteBackupVault(directoryURL: h.vault.directoryURL) { if $0 == .snapshotWrite { throw POSIXError(.ENOSPC) } }
        let controller = WordNoteDataProtection(session: h.session, store: h.store, vault: faulty, queue: h.queue, preferences: { before.content.preferences })
        controllers.append(controller)
        let preview = WordNoteVersionedRestorePreview(snapshot: try WordNoteSnapshotReader.decode(WordNoteSnapshotV2Codec.encode(before, kind: .manual)))
        do { try await controller.prepareRestore(preview); XCTFail("Expected backup failure.") }
        catch { XCTAssertEqual(error as? POSIXError, POSIXError(.ENOSPC)) }
        XCTAssertEqual(controller.restorePhase, .idle)
        XCTAssertFalse(WordNoteWriteGate.isBlocked(h.session.container.mainContext))
        XCTAssertEqual(try payload(h), before)
        XCTAssertTrue(h.queue.isSuspended)
        XCTAssertTrue(try h.store.open().analysisRequiresResume)
    }

    private struct Harness {
        let store: WordNoteRestoreStore
        let session: WordNoteStoreSession
        let vault: WordNoteBackupVault
        let queue: WordNoteV2AnalysisQueue
        let controller: WordNoteDataProtection
    }

    private func harness() async throws -> Harness {
        let directory = root.appending(path: "Data")
        let legacy = try WordNoteRestoreStore(directoryURL: directory).open()
        try WordNoteTestFixture.populated.populate(legacy.container.mainContext)
        let store = WordNoteRestoreStore(directoryURL: directory, targetSchema: .v2)
        let vault = WordNoteBackupVault(directoryURL: directory.appending(path: "Backups"))
        let session = try await WordNoteV2StartupCoordinator(store: store, vault: vault, preferences: { .init(appearance: "dark", defaultSource: "book") }).open()
        if session.preferencesToApply != nil { try store.acknowledgePreferences(for: session.generation) }
        let queue = try WordNoteV2AnalysisQueue(session: session, store: store, analysisHandler: WordNoteTestFixture.analysisResult)
        queues.append(queue)
        let controller = WordNoteDataProtection(session: session, store: store, vault: vault, queue: queue, preferences: { .init(appearance: "dark", defaultSource: "book") })
        controllers.append(controller)
        await controller.refresh()
        return Harness(store: store, session: session, vault: vault, queue: queue, controller: controller)
    }

    private func payload(_ h: Harness) throws -> WordNoteSnapshotV2Payload {
        try WordNoteSnapshotV2Payload.capture(from: h.session.container.mainContext, preferences: .init(appearance: "dark", defaultSource: "book"))
    }

    private func drain(_ queue: WordNoteV2AnalysisQueue) async throws {
        for _ in 0..<500 {
            if !queue.isBusy { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(queue.isBusy)
        XCTAssertNil(queue.errorMessage)
    }
}
