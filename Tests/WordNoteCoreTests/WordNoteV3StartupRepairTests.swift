import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3StartupRepairTests: XCTestCase {
    private var h: V3RecoveryHarness!
    private let now = V3TestSupport.date.addingTimeInterval(90)

    override func setUp() async throws { h = V3RecoveryHarness(directory: try V3TestSupport.directory()) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: h.directory); h = nil }

    func testPreviewIsReadOnlyAndConfirmedRepairRetainsFullEvidenceAndOriginalStore() async throws {
        let original = try await corruptedStore()
        let source = try raw(original)
        let journal = try Data(contentsOf: h.journalURL)
        let inventory = try await h.vault.inventory()
        let coordinator = coordinator()
        await expectFailure { try await coordinator.open() }
        await expectFailure({ try await coordinator.repair() }) { XCTAssertEqual($0 as? WordNoteStartupMigrationError, .repairUnavailable) }
        let report = try await coordinator.inspectV3Repair(at: now)
        XCTAssertEqual(report.detachableReferenceCount, 1)
        XCTAssertTrue(report.canPrepareRepair)
        XCTAssertEqual(try Data(contentsOf: h.journalURL), journal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path))
        XCTAssertNil(coordinator.repairReport)
        XCTAssertNil(coordinator.repairEvidence)
        let blocked = try XCTUnwrap(coordinator.sourceSession)
        let repaired = try await coordinator.repair()
        let expected = try WordNoteV3IntegrityService.prepareRepair(source, at: now).repairedPayload
        XCTAssertEqual(try h.capture(repaired), .v3(expected))
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertEqual(repaired.restoreOutcome, .repaired)
        XCTAssertNotEqual(repaired.generation, original.generation)
        XCTAssertEqual(repaired.analysisRequiresResume, WordNoteVersionedPayload.v3(expected).requiresAnalysisResume)
        XCTAssertEqual(try raw(original), source)
        XCTAssertTrue(WordNoteWriteGate.isBlocked(blocked.container.mainContext))
        XCTAssertFalse(blocked.container.mainContext.autosaveEnabled)
        let evidence = try await evidenceVault.read(id: XCTUnwrap(coordinator.v3RepairEvidence).id)
        XCTAssertEqual(evidence.payload, source)
        XCTAssertEqual(evidence.summary.generation, original.generation)
        XCTAssertEqual(evidence.summary.counts, source.counts)
        let next = try await self.coordinator().open()
        XCTAssertEqual(next.generation, repaired.generation)
        XCTAssertEqual(try h.capture(next), .v3(expected))
        let after = try await h.vault.inventory()
        XCTAssertEqual(after.snapshots, inventory.snapshots)
    }

    func testRequiredReviewDamageBlocksRepairWithoutWritingEvidenceOrJournal() async throws {
        let original = try await corruptedStore(required: true)
        let source = try raw(original)
        let before = try Data(contentsOf: h.journalURL)
        let coordinator = coordinator()
        await expectFailure { try await coordinator.open() }
        let report = try await coordinator.inspectV3Repair()
        XCTAssertTrue(report.requiresManualResolution)
        XCTAssertTrue(report.issues.contains { $0.entity == .sessionItem && $0.kind == .missingReference })
        await expectFailure({ try await coordinator.repair() }) { XCTAssertEqual($0 as? WordNoteStartupMigrationError, .repairUnavailable) }
        XCTAssertNil(coordinator.v3RepairEvidence)
        XCTAssertEqual(try Data(contentsOf: h.journalURL), before)
        XCTAssertEqual(try raw(original), source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path))
    }

    func testEvidenceWriteFailuresKeepWritesBlockedAndRequireFreshInspection() async throws {
        let original = try await corruptedStore()
        let source = try raw(original)
        for step in [WordNoteV3RepairEvidenceVault.Checkpoint.beforeWrite, .afterWrite] {
            let vault = WordNoteV3RepairEvidenceVault(directoryURL: evidenceURL) { if $0 == step { throw POSIXError(.ENOSPC) } }
            let failed = coordinator(evidence: vault)
            await expectFailure { try await failed.open() }
            try await failed.inspectV3Repair(at: now)
            await expectFailure({ try await failed.repair() }) { XCTAssertEqual($0 as? POSIXError, POSIXError(.ENOSPC)) }
            XCTAssertNil(failed.session)
            XCTAssertNil(try h.store.preparedGeneration(for: original.generation))
            XCTAssertEqual(try h.store.open().recoveryRequired, .repair)
            XCTAssertTrue(try h.store.open().analysisRequiresResume)
            let blocked = try XCTUnwrap(failed.sourceSession)
            XCTAssertTrue(WordNoteWriteGate.isBlocked(blocked.container.mainContext))
            XCTAssertThrowsError(try h.store.authorizeAnalysisResume(for: original.generation)) {
                XCTAssertEqual($0 as? WordNoteRestoreError, .repairIncomplete)
            }
            await expectFailure({ try await failed.repair() }) { XCTAssertEqual($0 as? WordNoteStartupMigrationError, .repairUnavailable) }
            XCTAssertEqual(try raw(original), source)
        }
        let retried = coordinator()
        await expectFailure { try await retried.open() }
        try await retried.inspectV3Repair(at: now)
        let repaired = try await retried.repair()
        XCTAssertEqual(repaired.restoreOutcome, .repaired)
    }

    func testStagingAndActivationFaultsRetainOriginalFullGraphAndVerifiedEvidence() async throws {
        let original = try await corruptedStore()
        let source = try raw(original)
        for step in [WordNoteRestoreStore.Checkpoint.stagingSaved, .prepareJournal, .activateJournal, .commitJournal] {
            let store = WordNoteRestoreStore(directoryURL: h.directory, targetSchema: .v3) { if $0 == step { throw POSIXError(.ENOSPC) } }
            let failed = coordinator(store: store)
            await expectFailure { try await failed.open() }
            try await failed.inspectV3Repair(at: now)
            await expectFailure { try await failed.repair() }
            XCTAssertNil(failed.session)
            XCTAssertEqual(failed.phase, .recoveryRequired)
            let evidence = try await evidenceVault.read(id: XCTUnwrap(failed.v3RepairEvidence).id)
            XCTAssertEqual(evidence.payload, source)
            XCTAssertEqual(try h.store.open().generation, original.generation)
            XCTAssertEqual(try h.store.open().recoveryRequired, .repair)
            XCTAssertNil(try h.store.preparedGeneration(for: original.generation))
            XCTAssertEqual(try raw(original), source)
            await expectFailure({ try await failed.repair() }) { XCTAssertEqual($0 as? WordNoteStartupMigrationError, .repairUnavailable) }
        }
    }

    func testPreferencesAndCardOnlyChangesInvalidatePreviewBeforeEvidenceCreation() async throws {
        let original = try await corruptedStore()
        var preferences = h.preferences
        let coordinator = WordNoteStartupCoordinator(store: h.store, vault: h.vault, preferences: { preferences })
        await expectFailure { try await coordinator.open() }
        try await coordinator.inspectV3Repair(at: now)
        preferences.appearance = "light"
        await expectFailure({ try await coordinator.repair() }) { XCTAssertEqual($0 as? WordNoteV3IntegrityError, .staleRepairPlan) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path))
        try await coordinator.inspectV3Repair(at: now)
        let context = try XCTUnwrap(coordinator.sourceSession?.container.mainContext)
        let card = try XCTUnwrap(context.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewCardModel>()).first)
        let cardID = card.id
        card.priorityRequestedAt = now
        try context.save()
        await expectFailure({ try await coordinator.repair() }) { XCTAssertEqual($0 as? WordNoteV3IntegrityError, .staleRepairPlan) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path))
        XCTAssertNil(try h.store.preparedGeneration(for: original.generation))
        try await coordinator.inspectV3Repair(at: now)
        let repaired = try await coordinator.repair()
        guard case .v3(let payload) = try h.capture(repaired) else { return XCTFail("Expected V3.") }
        XCTAssertEqual(payload.cards.first { $0.id == cardID }?.schedule.priorityRequestedAt, now)
        XCTAssertEqual(payload.content.content.preferences.appearance, "light")
    }

    func testUncommittedDraftIsNeitherSavedNorDiscardedByInspectionOrRepair() async throws {
        let original = try await corruptedStore()
        let source = try raw(original)
        let coordinator = coordinator()
        await expectFailure { try await coordinator.open() }
        try await coordinator.inspectV3Repair(at: now)
        let context = try XCTUnwrap(coordinator.sourceSession?.container.mainContext)
        let term = try XCTUnwrap(context.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()).first)
        term.chineseMeaning = "Unsaved synthetic text"
        await expectFailure({ try await coordinator.repair() }) { XCTAssertEqual($0 as? WordNoteV2ContentError, .unsavedChanges) }
        await expectFailure({ try await coordinator.inspectV3Repair() }) { XCTAssertEqual($0 as? WordNoteV2ContentError, .unsavedChanges) }
        XCTAssertEqual(term.chineseMeaning, "Unsaved synthetic text")
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(try raw(original), source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path))
    }

    func testCancellationDuringStagingPreservesEvidenceAndPreventsReentrantWrites() async throws {
        let original = try await corruptedStore()
        let checkpoint = BlockingRestoreCheckpoint()
        defer { checkpoint.release() }
        let failed = coordinator(store: h.blockingStore(checkpoint))
        await expectFailure { try await failed.open() }
        try await failed.inspectV3Repair(at: now)
        let task = Task { try await failed.repair() }
        await h.waitForCheckpoint(checkpoint)
        XCTAssertEqual(failed.phase, .staging)
        XCTAssertFalse(checkpoint.wasOnMainThread)
        await expectFailure({ try await failed.open() }) { XCTAssertEqual($0 as? WordNoteStartupMigrationError, .busy) }
        await expectFailure { try await failed.inspectV3Repair() }
        await expectFailure { try await failed.repair() }
        task.cancel()
        checkpoint.release()
        await expectFailure({ try await task.value }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertNil(try h.store.preparedGeneration(for: original.generation))
        XCTAssertNotNil(failed.v3RepairEvidence)
        XCTAssertEqual(try h.store.open().generation, original.generation)
        XCTAssertEqual(try h.store.open().recoveryRequired, .repair)
        XCTAssertTrue(WordNoteWriteGate.isBlocked(try XCTUnwrap(failed.sourceSession).container.mainContext))
    }

    func testReviewOnlyChangeDuringStagingCancelsOwnCopyAndRetainsLatestSource() async throws {
        let original = try await corruptedStore()
        let checkpoint = BlockingRestoreCheckpoint()
        defer { checkpoint.release() }
        let failed = coordinator(store: h.blockingStore(checkpoint))
        await expectFailure { try await failed.open() }
        try await failed.inspectV3Repair(at: now)
        let task = Task { try await failed.repair() }
        await h.waitForCheckpoint(checkpoint)
        let context = try XCTUnwrap(failed.sourceSession?.container.mainContext)
        let session = try XCTUnwrap(context.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewSessionModel>()).first)
        session.targetCardCount = 30
        try context.save()
        checkpoint.release()
        await expectFailure({ try await task.value }) { XCTAssertEqual($0 as? WordNoteV3IntegrityError, .staleRepairPlan) }
        XCTAssertNil(try h.store.preparedGeneration(for: original.generation))
        XCTAssertEqual(try raw(h.store.open()).sessions[0].targetCardCount, 30)
        XCTAssertEqual(try h.store.open().generation, original.generation)
    }

    func testLosingRepairCannotCancelAnotherPreparedGeneration() async throws {
        let original = try await corruptedStore()
        let plan = try WordNoteV3IntegrityService.prepareRepair(raw(original), at: now)
        let checkpoint = BlockingRestoreCheckpoint()
        defer { checkpoint.release() }
        let first = coordinator(store: h.blockingStore(checkpoint))
        await expectFailure { try await first.open() }
        try await first.inspectV3Repair(at: now)
        let task = Task { try await first.repair() }
        await h.waitForCheckpoint(checkpoint)
        let evidence = try await evidenceVault.read(id: XCTUnwrap(first.v3RepairEvidence).id)
        let winner = try await h.store.prepareRepair(plan, protectedBy: evidence, replacing: original.generation)
        checkpoint.release()
        await expectFailure({ try await task.value }) { XCTAssertEqual($0 as? WordNoteRestoreError, .restoreAlreadyPending) }
        XCTAssertEqual(try h.store.preparedGeneration(for: original.generation), winner.generation)
        let repaired = try await coordinator().open()
        XCTAssertEqual(repaired.generation, winner.generation)
        XCTAssertEqual(try h.capture(repaired), .v3(plan.repairedPayload))
    }

    func testPreparedRepairSurvivesRestartButInterruptedActivationRetainsOriginal() async throws {
        let original = try await corruptedStore()
        let source = try raw(original)
        let plan = try WordNoteV3IntegrityService.prepareRepair(source, at: now)
        let evidence = try await evidenceVault.create(source, generation: original.generation)
        try h.store.beginRepair(replacing: original.generation)
        _ = try await h.store.prepareRepair(plan, protectedBy: evidence, replacing: original.generation)
        var journal = try h.journal()
        var pending = try XCTUnwrap(journal["pending"] as? [String: Any])
        XCTAssertEqual(journal["version"] as? Int, 3)
        XCTAssertEqual(pending["operation"] as? String, "repair")
        pending["phase"] = "activating"
        journal["pending"] = pending
        try h.writeJournal(journal)
        await expectFailure { try await coordinator().open() }
        XCTAssertEqual(try h.store.open().generation, original.generation)
        XCTAssertEqual(try h.store.open().recoveryRequired, .repair)
        XCTAssertNil(try h.store.preparedGeneration(for: original.generation))
        let prepared = try await h.store.prepareRepair(plan, protectedBy: evidence, replacing: original.generation)
        let repaired = try await coordinator().open()
        XCTAssertEqual(repaired.generation, prepared.generation)
        XCTAssertEqual(repaired.restoreOutcome, .repaired)
        XCTAssertEqual(try h.capture(repaired), .v3(plan.repairedPayload))
        XCTAssertEqual(try raw(original), source)
    }

    func testLowLevelRepairRejectsMissingIntentWrongGenerationAndDifferentFullPayload() async throws {
        let original = try await corruptedStore()
        let source = try raw(original)
        let plan = try WordNoteV3IntegrityService.prepareRepair(source, at: now)
        let evidence = try await evidenceVault.create(source, generation: original.generation)
        await expectFailure({ try await h.store.prepareRepair(plan, protectedBy: evidence, replacing: original.generation) }) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .protectionRequired)
        }
        try h.store.beginRepair(replacing: original.generation)
        let wrong = try await evidenceVault.create(source, generation: .init(id: UUID()))
        await expectFailure({ try await h.store.prepareRepair(plan, protectedBy: wrong, replacing: original.generation) }) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .staleGeneration)
        }
        var changed = source
        changed.cards[0].schedule.priorityRequestedAt = now
        let mismatched = try await evidenceVault.create(changed, generation: original.generation)
        await expectFailure({ try await h.store.prepareRepair(plan, protectedBy: mismatched, replacing: original.generation) }) {
            XCTAssertEqual($0 as? WordNoteV3IntegrityError, .staleRepairPlan)
        }
        let healthyPlan = try WordNoteV3IntegrityService.prepareRepair(plan.repairedPayload, at: now)
        let healthyEvidence = try await evidenceVault.create(plan.repairedPayload, generation: original.generation)
        await expectFailure({ try await h.store.prepareRepair(healthyPlan, protectedBy: healthyEvidence, replacing: original.generation) }) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .protectionRequired)
        }
        XCTAssertNil(try h.store.preparedGeneration(for: original.generation))
        XCTAssertEqual(try raw(original), source)
    }

    func testMalformedRepairJournalNeverChangesSourceOrRewritesJournal() async throws {
        let original = try await corruptedStore()
        let source = try raw(original)
        let plan = try WordNoteV3IntegrityService.prepareRepair(source, at: now)
        let evidence = try await evidenceVault.create(source, generation: original.generation)
        try h.store.beginRepair(replacing: original.generation)
        _ = try await h.store.prepareRepair(plan, protectedBy: evidence, replacing: original.generation)
        let journal = try h.journal()
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["analysisRequiresResume"] = false },
            { var pending = $0["pending"] as! [String: Any]; pending["schemaVersion"] = "2.0.0"; $0["pending"] = pending },
            { var pending = $0["pending"] as! [String: Any]; pending["protectionSnapshotID"] = UUID().uuidString; $0["pending"] = pending }
        ]
        for change in changes {
            var invalid = journal
            change(&invalid)
            try h.writeJournal(invalid)
            let bytes = try Data(contentsOf: h.journalURL)
            XCTAssertThrowsError(try h.store.open()) { XCTAssertEqual($0 as? WordNoteRestoreError, .invalidJournal) }
            XCTAssertEqual(try Data(contentsOf: h.journalURL), bytes)
            XCTAssertEqual(try raw(original), source)
        }
    }

    func testManualRepairMustValidateReviewGraphBeforeExplicitAnalysisResume() async throws {
        let original = try await corruptedStore()
        try h.store.beginRepair(replacing: original.generation)
        XCTAssertThrowsError(try h.store.authorizeAnalysisResume(for: original.generation)) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .repairIncomplete)
        }
        let context = original.container.mainContext
        for term in try context.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()) { term.sourceRecordID = nil }
        let item = try XCTUnwrap(context.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewSessionItemModel>()).first)
        let originalSession = item.sessionID
        item.sessionID = UUID()
        try context.save()
        XCTAssertThrowsError(try h.store.authorizeAnalysisResume(for: original.generation)) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .repairIncomplete)
        }
        item.sessionID = originalSession
        try context.save()
        try h.store.authorizeAnalysisResume(for: original.generation)
        let opened = try h.store.open()
        XCTAssertFalse(opened.analysisRequiresResume)
        XCTAssertNil(opened.recoveryRequired)
        XCTAssertEqual(opened.generation, original.generation)
    }

    func testPortablePreferencesInvalidateOldRepairPreviewAndSurviveConfirmedRepair() async throws {
        let original = try await corruptedStore(), source = try raw(original)
        var learning = WordNoteLearningPreferences(defaultCourseID: source.content.content.courses[0].id,
            defaultLookupIntent: .chineseToEnglish, reviewTargetCards: 35, reviewDailyNewLimit: 7)
        let base = h.preferences
        let coordinator = WordNoteStartupCoordinator(store: h.store, vault: h.vault, preferences: { base },
            learningPreferences: { learning })
        await expectFailure { try await coordinator.open() }
        try await coordinator.inspectV3Repair(at: now)
        learning.reviewTargetCards = 40
        await expectFailure({ try await coordinator.repair() }) { XCTAssertEqual($0 as? WordNoteV3IntegrityError, .staleRepairPlan) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceURL.path))
        try await coordinator.inspectV3Repair(at: now)
        let repaired = try await coordinator.repair()
        let evidence = try await evidenceVault.read(id: XCTUnwrap(coordinator.v3RepairEvidence).id)
        XCTAssertEqual(evidence.payload.learningPreferences, learning)
        XCTAssertEqual(repaired.effectiveLearningPreferencesToApply, learning)
        guard case .v3(let payload) = try h.capture(repaired) else { return XCTFail("Expected V3") }
        XCTAssertEqual(payload.learningPreferences, learning)
        XCTAssertEqual(payload.cards, source.cards)
        XCTAssertEqual(payload.sessions, source.sessions)
        XCTAssertEqual(try h.journal()["version"] as? Int, 4)
    }

    func testPortablePreferenceChangeDuringRepairStagingCancelsOnlyOwnCopy() async throws {
        let original = try await corruptedStore()
        var learning = WordNoteLearningPreferences(reviewTargetCards: 35)
        let checkpoint = BlockingRestoreCheckpoint()
        defer { checkpoint.release() }
        let base = h.preferences
        let coordinator = WordNoteStartupCoordinator(store: h.blockingStore(checkpoint), vault: h.vault,
            preferences: { base }, learningPreferences: { learning })
        await expectFailure { try await coordinator.open() }
        try await coordinator.inspectV3Repair(at: now)
        let task = Task { try await coordinator.repair() }
        await h.waitForCheckpoint(checkpoint)
        learning.reviewTargetCards = 40
        checkpoint.release()
        await expectFailure({ try await task.value }) { XCTAssertEqual($0 as? WordNoteV3IntegrityError, .staleRepairPlan) }
        XCTAssertNil(try h.store.preparedGeneration(for: original.generation))
        XCTAssertEqual(try h.store.open().generation, original.generation)
        XCTAssertEqual(learning.reviewTargetCards, 40)
        let evidence = try await evidenceVault.read(id: XCTUnwrap(coordinator.v3RepairEvidence).id)
        XCTAssertEqual(evidence.payload.learningPreferences?.reviewTargetCards, 35)
    }

    private var evidenceURL: URL { h.vault.directoryURL.appending(path: "RepairEvidenceV3") }
    private var evidenceVault: WordNoteV3RepairEvidenceVault { .init(directoryURL: evidenceURL) }

    private func coordinator(store: WordNoteRestoreStore? = nil, evidence: WordNoteV3RepairEvidenceVault? = nil) -> WordNoteStartupCoordinator {
        let preferences = h.preferences
        return .init(store: store ?? h.store, vault: h.vault, preferences: { preferences }, v3EvidenceVault: evidence)
    }

    private func corruptedStore(required: Bool = false) async throws -> WordNoteStoreSession {
        let source = try await h.seed(.v3(try V3TestSupport.reviewedPayload()))
        try h.store.acknowledgePreferences(for: source.generation)
        let context = source.container.mainContext
        if required {
            let item = try XCTUnwrap(context.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewSessionItemModel>()).first)
            item.sessionID = UUID()
        } else {
            let term = try XCTUnwrap(context.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()).first)
            term.sourceRecordID = UUID()
        }
        try context.save()
        return source
    }

    private func raw(_ session: WordNoteStoreSession) throws -> WordNoteSnapshotV3Payload {
        let context = ModelContext(session.container)
        context.autosaveEnabled = false
        return try WordNoteSnapshotV3Payload.captureForIntegrityInspection(from: context, preferences: h.preferences)
    }

    private func expectFailure<T>(_ operation: () async throws -> T, verify: (Error) -> Void = { _ in },
                                  file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected failure.", file: file, line: line) }
        catch { verify(error) }
    }
}
