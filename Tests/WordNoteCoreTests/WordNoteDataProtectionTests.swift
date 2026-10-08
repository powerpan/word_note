import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteDataProtectionTests: XCTestCase {
    private var root: URL!
    private var controllers: [WordNoteDataProtection] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "data-protection-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        controllers.forEach { $0.stopAutomaticBackups() }
        controllers = []
        try? FileManager.default.removeItem(at: root)
    }

    func testManualBackupAndExportCaptureCurrentPreferencesAndAllData() async throws {
        let h = try harness()
        try await h.controller.createBackup()
        XCTAssertEqual(h.controller.snapshots.count, 1)
        let id = try XCTUnwrap(h.controller.snapshots.first?.id)
        let preview = try await h.controller.previewRestore(id: id)
        XCTAssertEqual(preview.snapshot.payload, try snapshot(h))
        XCTAssertFalse(WordNoteWriteGate.isBlocked(h.session.container.mainContext))
        let export = root.appending(path: "chosen-backup.json")
        try await h.controller.exportBackup(to: export)
        let decoded = try WordNoteSnapshotCodec.decode(Data(contentsOf: export))
        XCTAssertEqual(decoded.payload, try snapshot(h))
        let originalExport = root.appending(path: "chosen-existing-backup.json")
        try await h.controller.exportBackup(to: originalExport, id: id)
        XCTAssertEqual(try WordNoteSnapshotCodec.decode(Data(contentsOf: originalExport)).document.snapshotID, id)
    }

    func testExportsRejectManagedStoreDirectoryIncludingSymlinkAlias() async throws {
        let h = try harness()
        let target = h.store.directoryURL.appending(path: "store-generations.json")
        do { try await h.controller.exportBackup(to: target); XCTFail("Managed files must not be overwritten.") }
        catch { XCTAssertTrue(error is WordNoteDataOperationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let link = root.appending(path: "data-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: h.store.directoryURL)
        do { try await h.controller.exportBackup(to: link.appending(path: "anything.json")); XCTFail("Alias must be protected.") }
        catch { XCTAssertTrue(error is WordNoteDataOperationError) }
    }

    func testCSVExportsOnlyFrozenSelectedScope() async throws {
        let h = try harness()
        let before = try snapshot(h)
        let selected = [before.terms[0]]
        let url = root.appending(path: "selected.csv")
        try await h.controller.exportVocabulary(terms: selected, courses: before.courses, to: url)
        XCTAssertEqual(try Data(contentsOf: url), VocabularyCSVExporter.export(terms: selected, courses: before.courses))
        XCTAssertEqual(try snapshot(h), before)
    }

    func testPreviewFailureDoesNotCreateBackupOrPauseCurrentData() async throws {
        let h = try harness()
        let before = try snapshot(h)
        let url = root.appending(path: "broken.json")
        try PrivateFileIO.write(Data("invalid".utf8), to: url)
        do { _ = try await h.controller.previewRestore(url: url); XCTFail("Expected invalid document.") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotError, .invalidDocument) }
        XCTAssertEqual(try snapshot(h), before)
        XCTAssertFalse(h.controller.isRestoring)
        XCTAssertFalse(h.queue.isSuspended)
        XCTAssertTrue(h.controller.snapshots.isEmpty)
        XCTAssertFalse(try h.store.hasPreparedRestore(for: .legacy))
    }

    func testPreRestoreBackupFailurePreservesStoreAndRequiresExplicitAnalysisResume() async throws {
        let h = try harness(vaultFault: { checkpoint in
            if checkpoint == .snapshotWrite { throw POSIXError(.ENOSPC) }
        })
        let before = try snapshot(h)
        do { try await h.controller.prepareRestore(replacement(before)); XCTFail("Expected a full-disk failure.") }
        catch { XCTAssertEqual(error as? POSIXError, POSIXError(.ENOSPC)) }
        XCTAssertEqual(try snapshot(h), before)
        XCTAssertFalse(h.controller.isRestoring)
        XCTAssertFalse(WordNoteWriteGate.isBlocked(h.session.container.mainContext))
        XCTAssertFalse(try h.store.hasPreparedRestore(for: .legacy))
        XCTAssertTrue(h.queue.isSuspended)
        XCTAssertTrue(try h.store.open().analysisRequiresResume)
        try h.controller.resumeAnalysis()
        XCTAssertFalse(h.queue.isSuspended)
        XCTAssertFalse(try h.store.open().analysisRequiresResume)
    }

    func testPreparedRestoreProtectsAllContextsAndCancelRestoresAutosave() async throws {
        let h = try harness()
        let context = h.session.container.mainContext
        let before = try snapshot(h)
        let autosave = context.autosaveEnabled
        try await h.controller.prepareRestore(replacement(before))
        XCTAssertEqual(h.controller.restorePhase, .readyToQuit)
        XCTAssertFalse(context.autosaveEnabled)
        XCTAssertEqual(try snapshot(h), before)
        let otherContext = ModelContext(h.session.container)
        XCTAssertThrowsError(try InputRecordService(modelContext: otherContext).createDraft(rawText: "new", courseID: nil, sourceType: .other, note: nil))
        let protection = try XCTUnwrap(h.controller.snapshots.first { $0.kind == .beforeRestore })
        let protectedPayload = try await h.vault.readSnapshot(id: protection.id).payload
        XCTAssertEqual(protectedPayload, before)
        do { try await h.controller.createBackup(); XCTFail("Concurrent operations must be blocked.") }
        catch { XCTAssertTrue(error is WordNoteDataOperationError) }
        try h.controller.cancelRestore()
        XCTAssertFalse(h.controller.isRestoring)
        XCTAssertEqual(context.autosaveEnabled, autosave)
        XCTAssertNoThrow(try WordNoteWriteGate.check(otherContext))
        XCTAssertEqual(try h.store.open().generation, .legacy)
        XCTAssertTrue(h.queue.isSuspended)
    }

    func testRestoreObserverWorksWithoutAnyWindowAndEmitsOnlyAvailabilityTransitions() async throws {
        let h = try harness()
        var states: [Bool] = []
        h.controller.restoreStateDidChange = { states.append($0) }
        XCTAssertEqual(states, [false])
        try await h.controller.prepareRestore(replacement(snapshot(h)))
        XCTAssertEqual(states, [false, true])
        XCTAssertEqual(h.controller.restorePhase, .readyToQuit)
        try h.controller.cancelRestore()
        XCTAssertEqual(states, [false, true, false])
        h.controller.restoreStateDidChange = nil
        XCTAssertEqual(states, [false, true, false])
    }

    func testRestoreObserverResumesCaptureAfterRecoverablePreparationFailure() async throws {
        let h = try harness(vaultFault: { checkpoint in
            if checkpoint == .snapshotWrite { throw POSIXError(.ENOSPC) }
        })
        var states: [Bool] = []
        h.controller.restoreStateDidChange = { states.append($0) }
        do { try await h.controller.prepareRestore(replacement(snapshot(h))); XCTFail("Expected backup failure.") }
        catch { XCTAssertEqual(error as? POSIXError, POSIXError(.ENOSPC)) }
        XCTAssertEqual(states, [false, true, false])
        XCTAssertTrue(h.queue.isSuspended)
    }

    func testRestoreObserverKeepsCaptureSuspendedWhenRecoveryIsRequired() async throws {
        let journal = root.appending(path: "Data/store-generations.json")
        let h = try harness(vaultFault: { checkpoint in
            if checkpoint == .snapshotWrite {
                try PrivateFileIO.write(Data("damaged journal".utf8), to: journal)
                throw POSIXError(.ENOSPC)
            }
        })
        var states: [Bool] = []
        h.controller.restoreStateDidChange = { states.append($0) }
        do { try await h.controller.prepareRestore(replacement(snapshot(h))); XCTFail("Expected backup failure.") }
        catch { XCTAssertEqual(error as? POSIXError, POSIXError(.ENOSPC)) }
        XCTAssertEqual(h.controller.restorePhase, .recoveryRequired)
        XCTAssertEqual(states, [false, true])
        var attachedState: Bool?
        h.controller.restoreStateDidChange = { attachedState = $0 }
        XCTAssertEqual(attachedState, true)
    }

    func testStagingFailureReleasesGateButRetainsProtectedSnapshot() async throws {
        let h = try harness(storeFault: { checkpoint in
            if checkpoint == .stagingSaved { throw POSIXError(.ENOSPC) }
        })
        let before = try snapshot(h)
        do { try await h.controller.prepareRestore(replacement(before)); XCTFail("Expected staging failure.") }
        catch { XCTAssertEqual(error as? POSIXError, POSIXError(.ENOSPC)) }
        XCTAssertFalse(h.controller.isRestoring)
        XCTAssertFalse(WordNoteWriteGate.isBlocked(h.session.container.mainContext))
        XCTAssertEqual(try snapshot(h), before)
        let inventory = try await h.vault.inventory()
        XCTAssertEqual(inventory.snapshots.filter { $0.kind == .beforeRestore }.count, 1)
    }

    func testUnreadableJournalAfterFailureKeepsAllWritesBlocked() async throws {
        let journal = root.appending(path: "Data/store-generations.json")
        let h = try harness(vaultFault: { checkpoint in
            if checkpoint == .snapshotWrite {
                try PrivateFileIO.write(Data("damaged journal".utf8), to: journal)
                throw POSIXError(.ENOSPC)
            }
        })
        let before = try snapshot(h)
        do { try await h.controller.prepareRestore(replacement(before)); XCTFail("Expected failed restore.") }
        catch { XCTAssertEqual(error as? POSIXError, POSIXError(.ENOSPC)) }
        XCTAssertEqual(h.controller.restorePhase, .recoveryRequired)
        XCTAssertTrue(WordNoteWriteGate.isBlocked(h.session.container.mainContext))
        XCTAssertFalse(h.session.container.mainContext.autosaveEnabled)
        XCTAssertEqual(try snapshot(h), before)
        XCTAssertThrowsError(try h.controller.resumeAnalysis())
    }

    func testSecondRestoreCannotRaceFirstOperation() async throws {
        let h = try harness()
        let preview = try replacement(snapshot(h))
        let first = Task { try await h.controller.prepareRestore(preview) }
        for _ in 0..<100 where !h.controller.isRestoring { await Task.yield() }
        do { try await h.controller.prepareRestore(preview); XCTFail("Expected a busy coordinator.") }
        catch { XCTAssertTrue(error is WordNoteDataOperationError) }
        try await first.value
        XCTAssertEqual(h.controller.snapshots.filter { $0.kind == .beforeRestore }.count, 1)
        try h.controller.cancelRestore()
    }

    func testRestoreReopensNewStoreWithAnalysisPausedUntilUserAuthorizesIt() async throws {
        let h = try harness()
        let preview = try replacement(snapshot(h), pendingAnalysis: true)
        try await h.controller.prepareRestore(preview)
        let reopened = try h.store.open()
        XCTAssertEqual(reopened.restoreOutcome, .restored)
        var calls = 0
        let queue = QuickAddAnalysisQueue(modelContext: reopened.container.mainContext, initiallySuspended: reopened.analysisRequiresResume) { request in
            calls += 1
            return WordNoteTestFixture.analysisResult(for: request)
        }
        let controller = WordNoteDataProtection(session: reopened, store: h.store, vault: h.vault, queue: queue, preferences: { preview.snapshot.payload.preferences })
        controllers.append(controller)
        XCTAssertEqual(try queue.recoverPendingAnalyses(), 0)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: reopened.container.mainContext, preferences: preview.snapshot.payload.preferences), preview.snapshot.payload.canonicalized)
        try controller.resumeAnalysis()
        try await queue.waitUntilIdle()
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(try h.store.open().analysisRequiresResume)
    }

    func testAutomaticBackupHonorsChangeAndTwentyFourHourDeadline() async throws {
        let h = try harness()
        let start = Date()
        await h.controller.checkAutomaticBackup(now: start)
        XCTAssertEqual(h.controller.snapshots.count, 1)
        let term = try XCTUnwrap(h.session.container.mainContext.fetch(FetchDescriptor<TermModel>()).first)
        term.chineseMeaning = "changed"
        try h.session.container.mainContext.save()
        h.controller.noteDataChanged()
        await h.controller.checkAutomaticBackup(now: start.addingTimeInterval(60))
        XCTAssertEqual(h.controller.snapshots.count, 1)
        await h.controller.checkAutomaticBackup(now: start.addingTimeInterval(86_400))
        XCTAssertEqual(h.controller.snapshots.count, 2)
        await h.controller.checkAutomaticBackup(now: start.addingTimeInterval(172_800))
        XCTAssertEqual(h.controller.snapshots.count, 2)
    }

    func testAutomaticBackupSaveObservationWorksWithoutAnyView() async throws {
        let h = try harness(fixture: .empty)
        await h.controller.checkAutomaticBackup()
        h.controller.startAutomaticBackups()
        _ = try InputRecordService(modelContext: h.session.container.mainContext).createDraft(rawText: "new", courseID: nil, sourceType: .other, note: nil)
        for _ in 0..<150 {
            if !h.controller.snapshots.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(h.controller.snapshots.first?.counts.inputRecords, 1)
    }

    func testAutomaticCleanupRetriesBeforeNextBackupIsDue() async throws {
        let h = try harness()
        let payload = try snapshot(h)
        let failingCleanup = WordNoteBackupVault(directoryURL: h.vault.directoryURL) { checkpoint in
            if checkpoint == .pruning { throw POSIXError(.EACCES) }
        }
        let now = Date()
        for _ in 0..<8 { _ = try await failingCleanup.create(payload, kind: .automatic, now: now) }
        await h.controller.checkAutomaticBackup(now: now.addingTimeInterval(60))
        XCTAssertEqual(h.controller.snapshots.count, 7)
    }

    func testManualSnapshotDeletionDoesNotAlterVocabulary() async throws {
        let h = try harness()
        let before = try snapshot(h)
        try await h.controller.createBackup()
        let id = try XCTUnwrap(h.controller.snapshots.first?.id)
        try await h.controller.deleteBackup(id: id)
        XCTAssertTrue(h.controller.snapshots.isEmpty)
        XCTAssertEqual(try snapshot(h), before)
    }

    func testV1ControllerCanListV2BackupButRejectsRestoreWithoutChangingStore() async throws {
        let h = try harness()
        let before = try snapshot(h)
        let payload = try WordNoteV1ToV2Migration.convert(before).payload
        let saved = try await h.vault.create(payload, kind: .manual)
        await h.controller.refresh()
        XCTAssertEqual(h.controller.snapshots.first?.schemaVersion, .v2)
        do { _ = try await h.controller.previewRestore(id: saved.snapshot.id); XCTFail("V1 app must not accept a V2 restore.") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedSchema) }
        do { _ = try await h.controller.previewVersionedRestore(id: saved.snapshot.id); XCTFail("Versioned UI must also enforce the active V1 runtime.") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedSchema) }
        XCTAssertEqual(h.controller.restorePhase, .idle)
        XCTAssertFalse(h.controller.isRestoring)
        XCTAssertFalse(try h.store.hasPreparedRestore(for: h.session.generation))
        XCTAssertEqual(try snapshot(h), before)
    }

    private struct Harness {
        let store: WordNoteRestoreStore
        let session: WordNoteStoreSession
        let vault: WordNoteBackupVault
        let queue: QuickAddAnalysisQueue
        let controller: WordNoteDataProtection
    }

    private func harness(
        fixture: WordNoteTestFixture = .populated,
        vaultFault: (@Sendable (WordNoteBackupVault.Checkpoint) throws -> Void)? = nil,
        storeFault: (@Sendable (WordNoteRestoreStore.Checkpoint) throws -> Void)? = nil
    ) throws -> Harness {
        let store = WordNoteRestoreStore(directoryURL: root.appending(path: "Data"), fault: storeFault)
        let session = try store.open()
        try fixture.populate(session.container.mainContext)
        let vault = WordNoteBackupVault(directoryURL: store.directoryURL.appending(path: "Backups"), fault: vaultFault)
        let queue = QuickAddAnalysisQueue(modelContext: session.container.mainContext) { request in
            WordNoteTestFixture.analysisResult(for: request)
        }
        let controller = WordNoteDataProtection(session: session, store: store, vault: vault, queue: queue, preferences: { .init(appearance: "dark", defaultSource: "paper") })
        controllers.append(controller)
        return Harness(store: store, session: session, vault: vault, queue: queue, controller: controller)
    }

    private func snapshot(_ h: Harness) throws -> WordNoteSnapshotPayload {
        try WordNoteSnapshotPayload.capture(from: h.session.container.mainContext, preferences: .init(appearance: "dark", defaultSource: "paper"))
    }

    private func replacement(_ original: WordNoteSnapshotPayload, pendingAnalysis: Bool = false) throws -> WordNoteRestorePreview {
        var payload = original
        payload.terms[0].chineseMeaning = "replacement meaning"
        payload.preferences = .init(appearance: "light", defaultSource: "book")
        if pendingAnalysis { payload.inputRecords[0].statusRaw = "analyzing" }
        return WordNoteRestorePreview(snapshot: try WordNoteSnapshotCodec.decode(WordNoteSnapshotCodec.encode(payload, kind: .manual)))
    }
}
