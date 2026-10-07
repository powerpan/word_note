import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2StartupRepairTests: XCTestCase {
    private var directory: URL!
    private let preferences = WordNoteSnapshotPayload.Preferences(appearance: "light", defaultSource: "book")

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "startup-repair-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    func testRepairRequiresPreviewAndPreservesOriginalDataAndEvidence() async throws {
        let original = try await corruptedStore()
        let source = try raw(original)
        let journalBeforePreview = try Data(contentsOf: journalURL)
        let coordinator = makeCoordinator()
        await expectFailure { try await coordinator.open() }
        await expectFailure({ try await coordinator.repair() }) { XCTAssertEqual($0 as? WordNoteStartupMigrationError, .repairUnavailable) }
        let report = try await coordinator.inspectRepair(at: WordNoteV2ServiceTestSupport.now)
        XCTAssertEqual(report.detachableReferenceCount, 1)
        XCTAssertTrue(report.canPrepareRepair)
        XCTAssertEqual(try store.open().generation, original.generation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path))
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBeforePreview)
        let sourceSession = try XCTUnwrap(coordinator.sourceSession)
        let sourceContext = sourceSession.container.mainContext
        let repaired = try await coordinator.repair()
        let expected = try WordNoteV2IntegrityService.prepareRepair(source, at: WordNoteV2ServiceTestSupport.now).repairedPayload
        XCTAssertEqual(repaired.restoreOutcome, .repaired)
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertNotEqual(repaired.generation, original.generation)
        XCTAssertEqual(try capture(repaired), expected)
        XCTAssertEqual(repaired.analysisRequiresResume, WordNoteVersionedPayload.v2(expected).requiresAnalysisResume)
        XCTAssertEqual(try raw(original), source)
        withExtendedLifetime(sourceSession) {
            XCTAssertTrue(WordNoteWriteGate.isBlocked(sourceContext))
            XCTAssertFalse(sourceContext.autosaveEnabled)
        }
        let evidence = try XCTUnwrap(coordinator.repairEvidence)
        let retained = try await evidenceVault.read(id: evidence.id)
        XCTAssertEqual(retained.payload, source)
        XCTAssertEqual(retained.summary.generation, original.generation)
        let relaunched = try await makeCoordinator().open()
        XCTAssertEqual(relaunched.generation, repaired.generation)
        XCTAssertEqual(try capture(relaunched), expected)
        XCTAssertNil(relaunched.recoveryRequired)
        let inventory = try await vault.inventory()
        XCTAssertEqual(inventory.snapshots.count, 1)
        XCTAssertEqual(inventory.snapshots[0].kind, .beforeMigration)
    }

    func testRequiredRelationshipConflictIsReportedWithoutBackupOrRepair() async throws {
        let original = try await corruptedStore(requiredReference: true)
        let source = try raw(original)
        let coordinator = makeCoordinator()
        await expectFailure { try await coordinator.open() }
        let report = try await coordinator.inspectRepair()
        XCTAssertTrue(report.requiresManualResolution)
        XCTAssertFalse(report.canPrepareRepair)
        await expectFailure({ try await coordinator.repair() }) { XCTAssertEqual($0 as? WordNoteStartupMigrationError, .repairUnavailable) }
        XCTAssertEqual(try raw(original), source)
        XCTAssertEqual(try store.open().generation, original.generation)
        XCTAssertNil(try store.open().recoveryRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path))
    }

    func testEvidenceWriteFailureKeepsSourceBlockedAndCannotResumeAnalysis() async throws {
        let original = try await corruptedStore()
        let source = try raw(original)
        let failing = WordNoteRepairEvidenceVault(directoryURL: evidenceURL) { checkpoint in
            if checkpoint == .beforeWrite { throw POSIXError(.ENOSPC) }
        }
        let coordinator = makeCoordinator(evidence: failing)
        await expectFailure { try await coordinator.open() }
        try await coordinator.inspectRepair()
        await expectFailure({ try await coordinator.repair() }) { XCTAssertEqual($0 as? POSIXError, POSIXError(.ENOSPC)) }
        XCTAssertNil(coordinator.session)
        XCTAssertNil(try store.preparedGeneration(for: original.generation))
        XCTAssertEqual(try store.open().recoveryRequired, .repair)
        XCTAssertTrue(try store.open().analysisRequiresResume)
        XCTAssertThrowsError(try store.authorizeAnalysisResume(for: original.generation)) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .repairIncomplete)
        }
        XCTAssertEqual(try raw(original), source)
        let next = makeCoordinator()
        await expectFailure { try await next.open() }
        XCTAssertNil(next.repairEvidence)
        try await next.inspectRepair()
        let repaired = try await next.repair()
        XCTAssertEqual(repaired.restoreOutcome, .repaired)
    }

    func testFailuresBeforeActivationNeverChangeSourceAndRequireFreshPreview() async throws {
        let original = try await corruptedStore()
        let source = try raw(original)
        for failure in [WordNoteRestoreStore.Checkpoint.stagingSaved, .prepareJournal, .activateJournal, .commitJournal] {
            let failing = WordNoteRestoreStore(directoryURL: directory, targetSchema: .v2) { checkpoint in
                if checkpoint == failure { throw POSIXError(.ENOSPC) }
            }
            let coordinator = makeCoordinator(store: failing)
            await expectFailure { try await coordinator.open() }
            try await coordinator.inspectRepair()
            await expectFailure { try await coordinator.repair() }
            XCTAssertNotNil(coordinator.repairEvidence)
            XCTAssertNil(coordinator.session)
            XCTAssertEqual(try store.open().generation, original.generation)
            XCTAssertEqual(try store.open().recoveryRequired, .repair)
            XCTAssertNil(try store.preparedGeneration(for: original.generation))
            XCTAssertEqual(try raw(original), source)
            await expectFailure({ try await coordinator.repair() }) { XCTAssertEqual($0 as? WordNoteStartupMigrationError, .repairUnavailable) }
        }
    }

    func testSourceAndPreferenceChangesInvalidatePreviewWithoutEvidenceOrStaging() async throws {
        let original = try await corruptedStore()
        var currentPreferences = preferences
        let coordinator = WordNoteV2StartupCoordinator(store: store, vault: vault, preferences: { currentPreferences })
        await expectFailure { try await coordinator.open() }
        try await coordinator.inspectRepair()
        currentPreferences.appearance = "dark"
        await expectFailure({ try await coordinator.repair() }) { XCTAssertEqual($0 as? WordNoteV2IntegrityError, .staleRepairPlan) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path))
        try await coordinator.inspectRepair()
        let context = try XCTUnwrap(coordinator.sourceSession?.container.mainContext)
        let term = try XCTUnwrap(context.fetch(FetchDescriptor<WordNoteSchemaV2.TermModel>()).first)
        term.chineseMeaning = "A revised meaning"
        try context.save()
        await expectFailure({ try await coordinator.repair() }) { XCTAssertEqual($0 as? WordNoteV2IntegrityError, .staleRepairPlan) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path))
        XCTAssertNil(try store.preparedGeneration(for: original.generation))
        try await coordinator.inspectRepair()
        let termID = term.id
        let result = try await coordinator.repair()
        XCTAssertEqual(try capture(result).content.terms.first { $0.id == termID }?.chineseMeaning, "A revised meaning")
    }

    func testUnsavedChangesAreNeitherSavedNorDiscardedByInspection() async throws {
        let original = try await corruptedStore()
        let source = try raw(original)
        let coordinator = makeCoordinator()
        await expectFailure { try await coordinator.open() }
        let context = try XCTUnwrap(coordinator.sourceSession?.container.mainContext)
        let term = try XCTUnwrap(context.fetch(FetchDescriptor<WordNoteSchemaV2.TermModel>()).first)
        context.autosaveEnabled = false
        term.chineseMeaning = "Unsaved draft"
        await expectFailure({ try await coordinator.inspectRepair() }) { XCTAssertEqual($0 as? WordNoteV2ContentError, .unsavedChanges) }
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(term.chineseMeaning, "Unsaved draft")
        XCTAssertEqual(try raw(original), source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path))
    }

    func testExplicitResumeAfterManualRepairRevalidatesOriginalStore() async throws {
        let original = try await corruptedStore()
        try store.beginRepair(replacing: original.generation)
        XCTAssertThrowsError(try store.authorizeAnalysisResume(for: original.generation)) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .repairIncomplete)
        }
        let context = original.container.mainContext
        context.autosaveEnabled = false
        for term in try context.fetch(FetchDescriptor<WordNoteSchemaV2.TermModel>()) { term.sourceRecordID = nil }
        try context.save()
        let opened = try await makeCoordinator().open()
        XCTAssertEqual(opened.generation, original.generation)
        XCTAssertEqual(opened.recoveryRequired, .repair)
        XCTAssertTrue(opened.analysisRequiresResume)
        try store.authorizeAnalysisResume(for: original.generation)
        let resumed = try store.open()
        XCTAssertNil(resumed.recoveryRequired)
        XCTAssertFalse(resumed.analysisRequiresResume)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path))
    }

    func testInconsistentRecoveryMarkerIsRejectedWithoutJournalRewrite() async throws {
        _ = try await corruptedStore()
        let original = try readJournal()
        for recovery in ["migration", "repair"] {
            var invalid = original
            invalid["recoveryRequired"] = recovery
            invalid["analysisRequiresResume"] = recovery == "migration"
            let data = try JSONSerialization.data(withJSONObject: invalid)
            try PrivateFileIO.write(data, to: journalURL)
            XCTAssertThrowsError(try store.open()) { XCTAssertEqual($0 as? WordNoteRestoreError, .invalidJournal) }
            XCTAssertEqual(try Data(contentsOf: journalURL), data)
        }
    }

    func testCancellationDuringStagingKeepsEvidenceAndRejectsReentrantCalls() async throws {
        let original = try await corruptedStore()
        let checkpoint = BlockingRestoreCheckpoint()
        defer { checkpoint.release() }
        let coordinator = makeCoordinator(store: blockingStore(checkpoint))
        await expectFailure { try await coordinator.open() }
        try await coordinator.inspectRepair()
        let operation = Task { try await coordinator.repair() }
        await waitForCheckpoint(checkpoint)
        XCTAssertEqual(coordinator.phase, .staging)
        XCTAssertFalse(checkpoint.wasOnMainThread)
        await expectFailure({ try await coordinator.open() }) { XCTAssertEqual($0 as? WordNoteStartupMigrationError, .busy) }
        await expectFailure { try await coordinator.inspectRepair() }
        operation.cancel()
        checkpoint.release()
        await expectFailure({ try await operation.value }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertNotNil(coordinator.repairEvidence)
        XCTAssertNil(coordinator.session)
        XCTAssertNil(try store.preparedGeneration(for: original.generation))
        XCTAssertEqual(try store.open().generation, original.generation)
        XCTAssertEqual(try store.open().recoveryRequired, .repair)
    }

    func testSavedSourceChangeDuringStagingCancelsOnlyItsPendingGeneration() async throws {
        let original = try await corruptedStore()
        let checkpoint = BlockingRestoreCheckpoint()
        defer { checkpoint.release() }
        let coordinator = makeCoordinator(store: blockingStore(checkpoint))
        await expectFailure { try await coordinator.open() }
        try await coordinator.inspectRepair()
        let operation = Task { try await coordinator.repair() }
        await waitForCheckpoint(checkpoint)
        let context = try XCTUnwrap(coordinator.sourceSession?.container.mainContext)
        let term = try XCTUnwrap(context.fetch(FetchDescriptor<WordNoteSchemaV2.TermModel>()).first)
        term.chineseMeaning = "Changed during staging"
        try context.save()
        checkpoint.release()
        await expectFailure({ try await operation.value }) { XCTAssertEqual($0 as? WordNoteV2IntegrityError, .staleRepairPlan) }
        XCTAssertNil(try store.preparedGeneration(for: original.generation))
        XCTAssertEqual(try store.open().generation, original.generation)
        let current = try raw(try store.open())
        XCTAssertEqual(current.content.terms.first { $0.id == term.id }?.chineseMeaning, "Changed during staging")
    }

    func testPreparedRepairCompletesOnRestartAndInterruptedActivationReturnsToOriginal() async throws {
        let original = try await corruptedStore()
        let source = try raw(original)
        let plan = try WordNoteV2IntegrityService.prepareRepair(source, at: WordNoteV2ServiceTestSupport.now)
        let evidence = try await evidenceVault.create(source, generation: original.generation)
        try store.beginRepair(replacing: original.generation)
        _ = try await store.prepareRepair(plan, protectedBy: evidence, replacing: original.generation)
        var journal = try readJournal()
        var pending = try XCTUnwrap(journal["pending"] as? [String: Any])
        XCTAssertEqual(pending["operation"] as? String, "repair")
        pending["phase"] = "activating"
        journal["pending"] = pending
        try PrivateFileIO.write(JSONSerialization.data(withJSONObject: journal), to: journalURL)
        let interrupted = makeCoordinator()
        await expectFailure { try await interrupted.open() }
        XCTAssertEqual(try store.open().generation, original.generation)
        XCTAssertEqual(try store.open().recoveryRequired, .repair)
        XCTAssertNil(try store.preparedGeneration(for: original.generation))
        let prepared = try await store.prepareRepair(plan, protectedBy: evidence, replacing: original.generation)
        let repaired = try await makeCoordinator().open()
        XCTAssertEqual(repaired.generation, prepared.generation)
        XCTAssertEqual(repaired.restoreOutcome, .repaired)
        XCTAssertEqual(try capture(repaired), plan.repairedPayload)
        XCTAssertEqual(try raw(original), source)
    }

    func testLowLevelRepairRejectsMissingIntentWrongEvidenceAndMalformedPending() async throws {
        let original = try await corruptedStore()
        let source = try raw(original)
        let plan = try WordNoteV2IntegrityService.prepareRepair(source)
        let evidence = try await evidenceVault.create(source, generation: original.generation)
        await expectFailure({ try await store.prepareRepair(plan, protectedBy: evidence, replacing: original.generation) }) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .protectionRequired)
        }
        try store.beginRepair(replacing: original.generation)
        let wrong = try await evidenceVault.create(source, generation: WordNoteStoreGeneration(id: UUID()))
        await expectFailure({ try await store.prepareRepair(plan, protectedBy: wrong, replacing: original.generation) }) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .staleGeneration)
        }
        var changed = source
        changed.content.terms[0].chineseMeaning = "Other source"
        let mismatched = try await evidenceVault.create(changed, generation: original.generation)
        await expectFailure({ try await store.prepareRepair(plan, protectedBy: mismatched, replacing: original.generation) }) {
            XCTAssertEqual($0 as? WordNoteV2IntegrityError, .staleRepairPlan)
        }
        _ = try await store.prepareRepair(plan, protectedBy: evidence, replacing: original.generation)
        var journal = try readJournal()
        var pending = try XCTUnwrap(journal["pending"] as? [String: Any])
        pending["protectionSnapshotID"] = UUID().uuidString
        journal["pending"] = pending
        let bytes = try JSONSerialization.data(withJSONObject: journal)
        try PrivateFileIO.write(bytes, to: journalURL)
        XCTAssertThrowsError(try store.open()) { XCTAssertEqual($0 as? WordNoteRestoreError, .invalidJournal) }
        XCTAssertEqual(try Data(contentsOf: journalURL), bytes)
        XCTAssertEqual(try raw(original), source)
    }

    private var store: WordNoteRestoreStore { WordNoteRestoreStore(directoryURL: directory, targetSchema: .v2) }
    private var vault: WordNoteBackupVault { WordNoteBackupVault(directoryURL: directory.appending(path: "Backups")) }
    private var evidenceURL: URL { directory.appending(path: "Backups/RepairEvidence") }
    private var evidenceVault: WordNoteRepairEvidenceVault { WordNoteRepairEvidenceVault(directoryURL: evidenceURL) }
    private var journalURL: URL { directory.appending(path: "store-generations.json") }

    private func makeCoordinator(
        store selectedStore: WordNoteRestoreStore? = nil, evidence: WordNoteRepairEvidenceVault? = nil
    ) -> WordNoteV2StartupCoordinator {
        let preferences = preferences
        return WordNoteV2StartupCoordinator(store: selectedStore ?? store, vault: vault, preferences: { preferences }, evidenceVault: evidence)
    }

    private func corruptedStore(requiredReference: Bool = false) async throws -> WordNoteStoreSession {
        let legacy = try WordNoteRestoreStore(directoryURL: directory).open()
        try WordNoteTestFixture.populated.populate(legacy.container.mainContext)
        let migrated = try await makeCoordinator().open()
        try store.acknowledgePreferences(for: migrated.generation)
        let context = migrated.container.mainContext
        context.autosaveEnabled = false
        let term = try XCTUnwrap(context.fetch(FetchDescriptor<WordNoteSchemaV2.TermModel>()).first)
        if requiredReference { term.courseID = UUID() } else { term.sourceRecordID = UUID() }
        try context.save()
        return try store.open()
    }

    private func raw(_ session: WordNoteStoreSession) throws -> WordNoteSnapshotV2Payload {
        let context = ModelContext(session.container)
        context.autosaveEnabled = false
        return try WordNoteSnapshotV2Payload.captureForIntegrityInspection(from: context, preferences: preferences)
    }

    private func capture(_ session: WordNoteStoreSession) throws -> WordNoteSnapshotV2Payload {
        try WordNoteSnapshotV2Payload.capture(from: session.container.mainContext, preferences: preferences)
    }

    private func readJournal() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
    }

    private func blockingStore(_ checkpoint: BlockingRestoreCheckpoint) -> WordNoteRestoreStore {
        WordNoteRestoreStore(directoryURL: directory, targetSchema: .v2) { step in
            if step == .stagingSaved { try checkpoint.waitForRelease() }
        }
    }

    private func waitForCheckpoint(_ checkpoint: BlockingRestoreCheckpoint) async {
        for _ in 0..<1_000 {
            if checkpoint.isWaiting { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        checkpoint.release()
        XCTFail("Repair staging did not reach its checkpoint.")
    }

    private func expectFailure<T>(
        _ operation: () async throws -> T, verify: (Error) -> Void = { _ in },
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do { _ = try await operation(); XCTFail("Expected failure.", file: file, line: line) }
        catch { verify(error) }
    }
}
