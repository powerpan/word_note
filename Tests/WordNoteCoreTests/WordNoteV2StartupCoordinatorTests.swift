import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2StartupCoordinatorTests: XCTestCase {
    private var directory: URL!
    private let preferences = WordNoteSnapshotPayload.Preferences(appearance: "dark", defaultSource: "book")

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "startup-migration-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFrozenV1StoreIsProtectedThenMigratedAndRepeatedStartupDoesNotDuplicateData() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "v1", withExtension: "store", subdirectory: "Fixtures"))
        let bytes = try Data(contentsOf: fixture)
        try PrivateFileIO.prepareDirectory(directory)
        try FileManager.default.copyItem(at: fixture, to: legacyURL)
        let original = try legacyPayload()
        let coordinator = makeCoordinator()
        let session = try await coordinator.open()
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertEqual(session.schemaVersion, .v2)
        XCTAssertEqual(session.restoreOutcome, .migrated)
        XCTAssertNotEqual(session.generation, .legacy)
        XCTAssertNil(session.recoveryRequired)
        let expected = try WordNoteV1ToV2Migration.convert(original).payload
        XCTAssertEqual(try capture(session), .v2(expected))
        XCTAssertEqual(try legacyPayload(), original)
        let backup = try XCTUnwrap(coordinator.protectionBackup)
        XCTAssertEqual(backup.kind, .beforeMigration)
        let protected = try await vault.readSnapshot(id: backup.id)
        XCTAssertEqual(protected.payload, original)
        let same = try await coordinator.open()
        XCTAssertTrue(same.container === session.container)
        let relaunched = try await makeCoordinator().open()
        XCTAssertEqual(relaunched.restoreOutcome, .none)
        XCTAssertEqual(relaunched.generation, session.generation)
        XCTAssertEqual(try capture(relaunched), .v2(expected))
        let inventory = try await vault.inventory()
        XCTAssertEqual(inventory.snapshots.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture), bytes)
    }

    func testEmptyFirstStoreStillGetsAMigrationProtectionBackup() async throws {
        let coordinator = makeCoordinator()
        let session = try await coordinator.open()
        XCTAssertEqual(session.schemaVersion, .v2)
        XCTAssertEqual(try capture(session).counts.total, 0)
        XCTAssertFalse(session.analysisRequiresResume)
        let inventory = try await vault.inventory()
        XCTAssertEqual(inventory.snapshots.map(\.kind), [.beforeMigration])
        XCTAssertEqual(inventory.snapshots.first?.counts.total, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testBackupFailurePersistsPauseAndRequiresExplicitRetryAcrossRestarts() async throws {
        let original = try populateLegacy()
        let failingVault = WordNoteBackupVault(directoryURL: backupURL) { checkpoint in
            if checkpoint == .snapshotWrite { throw POSIXError(.ENOSPC) }
        }
        let failed = makeCoordinator(vault: failingVault)
        await assertThrowsAsync({ try await failed.open() }) { XCTAssertEqual($0 as? POSIXError, POSIXError(.ENOSPC)) }
        XCTAssertEqual(failed.phase, .recoveryRequired)
        XCTAssertNil(failed.session)
        XCTAssertTrue(WordNoteWriteGate.isBlocked(try XCTUnwrap(failed.sourceSession).container.mainContext))
        let resumed = try store.open()
        XCTAssertEqual(resumed.schemaVersion, .v1)
        XCTAssertEqual(resumed.recoveryRequired, .migration)
        XCTAssertTrue(resumed.analysisRequiresResume)
        XCTAssertThrowsError(try store.authorizeAnalysisResume(for: .legacy)) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .migrationIncomplete)
        }
        let next = makeCoordinator()
        await assertThrowsAsync({ try await next.open() }) { XCTAssertEqual($0 as? WordNoteStartupMigrationError, .recoveryRequired) }
        let beforeRetry = try await vault.inventory()
        XCTAssertTrue(beforeRetry.snapshots.isEmpty)
        let upgraded = try await next.open(retryMigration: true)
        XCTAssertEqual(upgraded.restoreOutcome, .migrated)
        XCTAssertEqual(try capture(upgraded), .v2(try WordNoteV1ToV2Migration.convert(original).payload))
        XCTAssertEqual(try legacyPayload(), original)
    }

    func testCatalogFailureKeepsReadableProtectionAndDoesNotStageMigration() async throws {
        let original = try populateLegacy()
        let failingVault = WordNoteBackupVault(directoryURL: backupURL) { checkpoint in
            if checkpoint == .catalogWrite { throw POSIXError(.ENOSPC) }
        }
        let failed = makeCoordinator(vault: failingVault)
        await assertThrowsAsync({ try await failed.open() }) { XCTAssertEqual($0 as? POSIXError, POSIXError(.ENOSPC)) }
        XCTAssertNil(try store.preparedGeneration(for: .legacy))
        XCTAssertEqual(try legacyPayload(), original)
        let inventory = try await vault.inventory()
        XCTAssertEqual(inventory.snapshots.count, 1)
        let saved = try await vault.readSnapshot(id: XCTUnwrap(inventory.snapshots.first?.id))
        XCTAssertEqual(saved.payload, original)
        XCTAssertEqual(try store.open().recoveryRequired, .migration)
    }

    func testProtectionIsRereadAndComparedBeforeAnyStaging() async throws {
        let original = try populateLegacy()
        let backupDirectory = backupURL
        let tamperingVault = WordNoteBackupVault(directoryURL: backupDirectory) { checkpoint in
            guard checkpoint == .catalogWrite else { return }
            let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasSuffix(".wordnote-backup.json") })
            let decoded = try WordNoteSnapshotCodec.decode(Data(contentsOf: url))
            var different = decoded.payload
            different.terms[0].chineseMeaning = "Not the current source data"
            try PrivateFileIO.write(WordNoteSnapshotCodec.encode(
                different, kind: .beforeMigration, snapshotID: decoded.document.snapshotID
            ), to: url)
        }
        let coordinator = makeCoordinator(vault: tamperingVault)
        await assertThrowsAsync({ try await coordinator.open() }) {
            XCTAssertEqual($0 as? WordNoteStartupMigrationError, .protectionMismatch)
        }
        XCTAssertNil(try store.preparedGeneration(for: .legacy))
        XCTAssertEqual(try legacyPayload(), original)
        XCTAssertEqual(try store.open().recoveryRequired, .migration)
    }

    func testStagingFailureRetainsOriginalAndProtectionWithoutAutomaticRetry() async throws {
        let original = try populateLegacy()
        let failing = WordNoteRestoreStore(directoryURL: directory, targetSchema: .v2) { checkpoint in
            if checkpoint == .stagingSaved { throw POSIXError(.ENOSPC) }
        }
        let coordinator = makeCoordinator(store: failing)
        await assertThrowsAsync({ try await coordinator.open() }) { XCTAssertEqual($0 as? POSIXError, POSIXError(.ENOSPC)) }
        XCTAssertNotNil(coordinator.protectionBackup)
        XCTAssertEqual(try legacyPayload(), original)
        XCTAssertNil(try store.preparedGeneration(for: .legacy))
        await assertThrowsAsync({ try await makeCoordinator().open() }) {
            XCTAssertEqual($0 as? WordNoteStartupMigrationError, .recoveryRequired)
        }
        let inventory = try await vault.inventory()
        XCTAssertEqual(inventory.snapshots.count, 1)
    }

    func testActivationAndCommitFailuresKeepDurableRecoveryUntilExplicitRetry() async throws {
        let original = try populateLegacy()
        for failure in [WordNoteRestoreStore.Checkpoint.activateJournal, .commitJournal] {
            let failing = WordNoteRestoreStore(directoryURL: directory, targetSchema: .v2) { checkpoint in
                if checkpoint == failure { throw POSIXError(.ENOSPC) }
            }
            let coordinator = makeCoordinator(store: failing)
            await assertThrowsAsync({ try await coordinator.open(retryMigration: true) }) {
                XCTAssertEqual($0 as? WordNoteStartupMigrationError, .recoveryRequired)
            }
            let originalSession = try store.open()
            XCTAssertEqual(originalSession.schemaVersion, .v1)
            XCTAssertEqual(originalSession.recoveryRequired, .migration)
            XCTAssertEqual(try legacyPayload(), original)
            XCTAssertNil(try store.preparedGeneration(for: .legacy))
        }
        let recovered = try await makeCoordinator().open(retryMigration: true)
        XCTAssertEqual(recovered.schemaVersion, .v2)
        XCTAssertNil(recovered.recoveryRequired)
        XCTAssertEqual(try legacyPayload(), original)
        let inventory = try await vault.inventory()
        XCTAssertEqual(inventory.snapshots.filter { $0.kind == .beforeMigration }.count, 3)
    }

    func testPreparedMigrationCompletesOnRestartWithoutCreatingAnotherProtection() async throws {
        let original = try populateLegacy()
        let prepared = try await prepareMigration(original)
        let coordinator = makeCoordinator()
        let session = try await coordinator.open()
        XCTAssertEqual(session.restoreOutcome, .migrated)
        XCTAssertEqual(session.generation, prepared.generation)
        XCTAssertEqual(try capture(session), .v2(try WordNoteV1ToV2Migration.convert(original).payload))
        let inventory = try await vault.inventory()
        XCTAssertEqual(inventory.snapshots.count, 1)
    }

    func testInterruptedActivationDoesNotAutomaticallyStartAnotherMigration() async throws {
        let original = try populateLegacy()
        _ = try await prepareMigration(original)
        var journal = try journalObject()
        var pending = try XCTUnwrap(journal["pending"] as? [String: Any])
        pending["phase"] = "activating"
        journal["pending"] = pending
        try PrivateFileIO.write(JSONSerialization.data(withJSONObject: journal), to: journalURL)
        for _ in 0..<2 {
            await assertThrowsAsync({ try await makeCoordinator().open() }) {
                XCTAssertEqual($0 as? WordNoteStartupMigrationError, .recoveryRequired)
            }
        }
        XCTAssertEqual(try legacyPayload(), original)
        XCTAssertNil(try store.preparedGeneration(for: .legacy))
        XCTAssertEqual(try store.open().recoveryRequired, .migration)
        let inventory = try await vault.inventory()
        XCTAssertEqual(inventory.snapshots.count, 1)
    }

    func testCancelledStartupKeepsAllWritersBlockedAndDoesNotPrepareOrActivate() async throws {
        let original = try populateLegacy()
        let checkpoint = BlockingRestoreCheckpoint()
        let coordinator = makeCoordinator(store: blockingStore(checkpoint))
        let task = Task { try await coordinator.open() }
        await waitForCheckpoint(checkpoint)
        let source = try XCTUnwrap(coordinator.sourceSession)
        XCTAssertEqual(coordinator.phase, .staging)
        XCTAssertFalse(checkpoint.wasOnMainThread)
        XCTAssertTrue(WordNoteWriteGate.isBlocked(source.container.mainContext))
        let other = ModelContext(source.container)
        XCTAssertThrowsError(try InputRecordService(modelContext: other).createDraft(rawText: "blocked", courseID: nil, sourceType: .other, note: nil))
        await assertThrowsAsync({ try await coordinator.open() }) { XCTAssertEqual($0 as? WordNoteStartupMigrationError, .busy) }
        task.cancel()
        checkpoint.release()
        await assertThrowsAsync({ try await task.value }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(WordNoteWriteGate.isBlocked(source.container.mainContext))
        XCTAssertFalse(source.container.mainContext.autosaveEnabled)
        XCTAssertNil(try store.preparedGeneration(for: .legacy))
        XCTAssertEqual(try legacyPayload(), original)
        XCTAssertEqual(try store.open().recoveryRequired, .migration)
    }

    func testSavedSourceChangeDuringStagingCancelsOnlyItsPreparedCopy() async throws {
        _ = try populateLegacy()
        let checkpoint = BlockingRestoreCheckpoint()
        let coordinator = makeCoordinator(store: blockingStore(checkpoint))
        let task = Task { try await coordinator.open() }
        await waitForCheckpoint(checkpoint)
        let context = try XCTUnwrap(coordinator.sourceSession).container.mainContext
        let term = try XCTUnwrap(context.fetch(FetchDescriptor<WordNoteSchemaV1.TermModel>()).first)
        term.chineseMeaning = "Direct write outside the service boundary"
        try context.save()
        let latest = try WordNoteSnapshotPayload.capture(from: context, preferences: preferences)
        checkpoint.release()
        await assertThrowsAsync({ try await task.value }) { XCTAssertEqual($0 as? WordNoteStartupMigrationError, .sourceChanged) }
        XCTAssertNil(try store.preparedGeneration(for: .legacy))
        XCTAssertEqual(try legacyPayload(), latest)
        XCTAssertEqual(try store.open().recoveryRequired, .migration)
        let retried = try await makeCoordinator().open(retryMigration: true)
        XCTAssertEqual(try capture(retried), .v2(try WordNoteV1ToV2Migration.convert(latest).payload))
    }

    func testUnsavedSourceChangeDuringStagingIsNotCommittedOrDiscarded() async throws {
        let original = try populateLegacy()
        let checkpoint = BlockingRestoreCheckpoint()
        let coordinator = makeCoordinator(store: blockingStore(checkpoint))
        let task = Task { try await coordinator.open() }
        await waitForCheckpoint(checkpoint)
        let context = try XCTUnwrap(coordinator.sourceSession).container.mainContext
        let term = try XCTUnwrap(context.fetch(FetchDescriptor<WordNoteSchemaV1.TermModel>()).first)
        term.chineseMeaning = "Unsubmitted direct edit"
        checkpoint.release()
        await assertThrowsAsync({ try await task.value }) { XCTAssertEqual($0 as? WordNoteV2ContentError, .unsavedChanges) }
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(term.chineseMeaning, "Unsubmitted direct edit")
        XCTAssertEqual(try legacyPayload(), original)
        XCTAssertNil(try store.preparedGeneration(for: .legacy))
        context.rollback()
    }

    func testCompetingRestoreIsNeitherOverwrittenNorCancelledByStartupFailure() async throws {
        let original = try populateLegacy()
        let replacement = try WordNoteSnapshotReader.decode(WordNoteSnapshotCodec.encode(original, kind: .manual))
        let protection = try await vault.create(original, kind: .beforeRestore)
        let checkpoint = BlockingRestoreCheckpoint()
        let coordinator = makeCoordinator(store: blockingStore(checkpoint))
        let task = Task { try await coordinator.open() }
        await waitForCheckpoint(checkpoint)
        let winner = try await store.prepareRestore(replacement, replacing: .legacy, protectedBy: protection.snapshot)
        checkpoint.release()
        await assertThrowsAsync({ try await task.value }) { XCTAssertEqual($0 as? WordNoteRestoreError, .restoreAlreadyPending) }
        XCTAssertEqual(try store.preparedGeneration(for: .legacy), winner)
        XCTAssertEqual(try legacyPayload(), original)
        let completed = try await makeCoordinator().open()
        XCTAssertEqual(completed.generation, winner)
        XCTAssertEqual(completed.restoreOutcome, .restored)
    }

    func testMissingSourceAfterMigrationIntentDoesNotCreateEmptyReplacement() async throws {
        _ = try populateLegacy()
        try store.beginMigration(replacing: .legacy)
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: legacyURL.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        await assertThrowsAsync({ try await makeCoordinator().open(retryMigration: true) }) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .missingStore)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        let inventory = try await vault.inventory()
        XCTAssertTrue(inventory.snapshots.isEmpty)
    }

    func testBrokenV1ReferencesAreRetainedAndNeverReachStaging() async throws {
        _ = try populateLegacy()
        let missingID = UUID()
        let candidateID = try autoreleasepool {
            let container = try legacyContainer()
            let candidate = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV1.CandidateTermModel>()).first)
            candidate.inputRecordID = missingID
            try container.mainContext.save()
            return candidate.id
        }
        let coordinator = makeCoordinator()
        await assertThrowsAsync({ try await coordinator.open() }) { XCTAssertEqual($0 as? WordNoteSnapshotError, .missingReference) }
        XCTAssertNil(coordinator.session)
        XCTAssertNil(try store.preparedGeneration(for: .legacy))
        let container = try legacyContainer()
        defer { withExtendedLifetime(container) {} }
        let candidates = try container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV1.CandidateTermModel>())
        XCTAssertEqual(candidates.first { $0.id == candidateID }?.inputRecordID, missingID)
        XCTAssertEqual(candidates.count, 3)
        let inventory = try await vault.inventory()
        XCTAssertTrue(inventory.snapshots.isEmpty)
    }

    func testMigrationWarningsPreserveLegacyContentAndAreReturnedWithoutText() async throws {
        _ = try populateLegacy()
        try autoreleasepool {
            let container = try legacyContainer()
            let term = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV1.TermModel>()).first)
            term.term = "\u{4E2D}\u{6587}"
            term.normalizedTerm = TextNormalizer.normalized(term.term)
            let candidate = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV1.CandidateTermModel>()).first)
            candidate.status = .saved
            try container.mainContext.save()
        }
        let original = try legacyPayload()
        let expected = try WordNoteV1ToV2Migration.convert(original)
        let coordinator = makeCoordinator()
        let session = try await coordinator.open()
        XCTAssertEqual(coordinator.migrationIssues, expected.issues)
        XCTAssertTrue(coordinator.migrationIssues.contains { $0.kind == .legacySubjectNeedsReview })
        XCTAssertTrue(coordinator.migrationIssues.contains { $0.kind == .unresolvedSavedCandidate })
        XCTAssertEqual(try capture(session), .v2(expected.payload))
        XCTAssertEqual(try legacyPayload(), original)
    }

    func testInvalidExistingV2StoreIsPreservedAndNeverExposedAsReady() async throws {
        _ = try populateLegacy()
        let existing = try await makeCoordinator().open()
        let term = try XCTUnwrap(existing.container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV2.TermModel>()).first)
        let missingID = UUID()
        term.sourceRecordID = missingID
        try existing.container.mainContext.save()
        let coordinator = makeCoordinator()
        await assertThrowsAsync({ try await coordinator.open() }) { XCTAssertEqual($0 as? WordNoteSnapshotError, .missingReference) }
        XCTAssertNil(coordinator.session)
        XCTAssertEqual(coordinator.phase, .recoveryRequired)
        let reopened = try store.open()
        let terms = try reopened.container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV2.TermModel>())
        XCTAssertEqual(terms.first { $0.id == term.id }?.sourceRecordID, missingID)
        XCTAssertEqual(reopened.generation, existing.generation)
        let inventory = try await vault.inventory()
        XCTAssertEqual(inventory.snapshots.count, 1)
    }

    func testLowLevelMigrationRequiresIntentAndExactProtectionKindAndCancellationToken() async throws {
        let original = try populateLegacy()
        for kind in [WordNoteBackupKind.manual, .beforeRestore] {
            let backup = try await vault.create(original, kind: kind)
            let decoded = try await vault.readSnapshot(id: backup.snapshot.id)
            await assertThrowsAsync({ try await store.prepareMigration(decoded, replacing: .legacy) }) {
                XCTAssertEqual($0 as? WordNoteRestoreError, .protectionRequired)
            }
        }
        let backup = try await vault.create(original, kind: .beforeMigration)
        let decoded = try await vault.readSnapshot(id: backup.snapshot.id)
        await assertThrowsAsync({ try await store.prepareMigration(decoded, replacing: .legacy) }) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .invalidJournal)
        }
        try store.beginMigration(replacing: .legacy)
        let prepared = try await store.prepareMigration(decoded, replacing: .legacy)
        let pending = try XCTUnwrap(journalObject()["pending"] as? [String: Any])
        XCTAssertEqual(pending["operation"] as? String, "migration")
        XCTAssertEqual(pending["sourceSnapshotID"] as? String, pending["protectionSnapshotID"] as? String)
        XCTAssertThrowsError(try store.cancelPreparedRestore(replacing: .legacy, expectedPending: .legacy)) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .staleGeneration)
        }
        XCTAssertEqual(try store.preparedGeneration(for: .legacy), prepared.generation)
        try store.cancelPreparedRestore(replacing: .legacy, expectedPending: prepared.generation)
        XCTAssertNil(try store.preparedGeneration(for: .legacy))
        XCTAssertEqual(try store.open().recoveryRequired, .migration)
        XCTAssertEqual(try legacyPayload(), original)
    }

    private var legacyURL: URL { directory.appending(path: "WordNote.store") }
    private var journalURL: URL { directory.appending(path: "store-generations.json") }
    private var backupURL: URL { directory.appending(path: "Backups") }
    private var store: WordNoteRestoreStore { WordNoteRestoreStore(directoryURL: directory, targetSchema: .v2) }
    private var vault: WordNoteBackupVault { WordNoteBackupVault(directoryURL: backupURL) }

    private func makeCoordinator(
        store selectedStore: WordNoteRestoreStore? = nil, vault selectedVault: WordNoteBackupVault? = nil
    ) -> WordNoteV2StartupCoordinator {
        let preferences = preferences
        return WordNoteV2StartupCoordinator(store: selectedStore ?? store, vault: selectedVault ?? vault, preferences: { preferences })
    }

    private func populateLegacy() throws -> WordNoteSnapshotPayload {
        try autoreleasepool {
            let session = try WordNoteRestoreStore(directoryURL: directory).open()
            try WordNoteTestFixture.populated.populate(session.container.mainContext)
            return try WordNoteSnapshotPayload.capture(from: session.container.mainContext, preferences: preferences)
        }
    }

    private func legacyContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration("WordNote", schema: schema, url: legacyURL)])
    }

    private func legacyPayload() throws -> WordNoteSnapshotPayload {
        try autoreleasepool {
            let container = try legacyContainer()
            return try withExtendedLifetime(container) {
                try WordNoteSnapshotPayload.capture(from: container.mainContext, preferences: preferences)
            }
        }
    }

    private func capture(_ session: WordNoteStoreSession) throws -> WordNoteVersionedPayload {
        try WordNoteVersionedPayload.capture(from: session.container.mainContext, preferences: preferences)
    }

    private func prepareMigration(_ original: WordNoteSnapshotPayload) async throws -> WordNotePreparedStore {
        try store.beginMigration(replacing: .legacy)
        let result = try await vault.create(original, kind: .beforeMigration)
        let protection = try await vault.readSnapshot(id: result.snapshot.id)
        return try await store.prepareMigration(protection, replacing: .legacy)
    }

    private func journalObject() throws -> [String: Any] {
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
        XCTFail("Migration staging did not reach its checkpoint.")
    }

    private func assertThrowsAsync<T>(
        _ operation: () async throws -> T, verify: (Error) -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do { _ = try await operation(); XCTFail("Expected failure.", file: file, line: line) }
        catch { verify(error) }
    }
}
