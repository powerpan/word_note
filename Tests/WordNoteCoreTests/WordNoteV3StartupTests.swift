import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3StartupTests: XCTestCase {
    private var h: V3RecoveryHarness!

    override func setUp() async throws { h = V3RecoveryHarness(directory: try V3TestSupport.directory()) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: h.directory); h = nil }

    func testFrozenV1DatabaseMigratesDirectlyToV3WithOneVerifiedProtection() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "v1", withExtension: "store", subdirectory: "Fixtures"))
        let bytes = try Data(contentsOf: fixture)
        try FileManager.default.copyItem(at: fixture, to: h.directory.appending(path: "WordNote.store"))
        let old = try h.store(.v1).open()
        let original = try h.capture(old)
        guard case .v1(let legacy) = original else { return XCTFail("Expected V1 fixture.") }
        let coordinator = coordinator()
        let migrated = try await coordinator.open()
        let backup = try XCTUnwrap(coordinator.protectionBackup)
        XCTAssertEqual(backup.schemaVersion, .v1)
        let expected = try WordNoteV2ToV3Migration.convert(WordNoteV1ToV2Migration.convert(legacy).payload, at: backup.createdAt)
        XCTAssertEqual(try h.capture(migrated), .v3(expected))
        XCTAssertEqual(migrated.restoreOutcome, .migrated)
        XCTAssertEqual(try h.capture(old), original)
        let inventory = try await h.vault.inventory()
        XCTAssertEqual(inventory.snapshots.map(\.kind), [.beforeMigration])
        XCTAssertEqual(try Data(contentsOf: fixture), bytes)
        XCTAssertTrue(expected.cards.allSatisfy { $0.createdAt == backup.createdAt })
    }

    func testV2UpgradeKeepsHistoricalDataAndRepeatedStartupDoesNotDuplicateCards() async throws {
        let payload = try V3TestSupport.source()
        let source = try await h.seed(.v2(payload))
        let before = try await h.vault.inventory()
        let coordinator = coordinator()
        let upgraded = try await coordinator.open()
        let backup = try XCTUnwrap(coordinator.protectionBackup)
        let expected = try WordNoteV2ToV3Migration.convert(payload, at: backup.createdAt)
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertNil(coordinator.sourceSession)
        XCTAssertEqual(upgraded.schemaVersion, .v3)
        XCTAssertEqual(upgraded.restoreOutcome, .migrated)
        XCTAssertEqual(try h.capture(upgraded), .v3(expected))
        XCTAssertEqual(try h.capture(source), .v2(payload.canonicalized))
        XCTAssertEqual(expected.cards.count, payload.content.terms.count)
        XCTAssertEqual(expected.cards.filter { $0.schedule.nextReviewAt != nil }.count, payload.content.terms.filter { $0.nextReviewAt != nil }.count)
        XCTAssertTrue(expected.sessionItems.isEmpty)
        let repeated = try await coordinator.open()
        XCTAssertTrue(repeated.container === upgraded.container)
        let restarted = try await self.coordinator().open()
        XCTAssertEqual(restarted.generation, upgraded.generation)
        XCTAssertEqual(try h.capture(restarted), .v3(expected))
        let after = try await h.vault.inventory()
        XCTAssertEqual(after.snapshots.count, before.snapshots.count + 1)
        let verified = try await h.vault.readVersionedSnapshot(id: backup.id)
        XCTAssertEqual(verified.payload, .v2(payload.canonicalized))
        for version in [WordNoteDataSchemaVersion.v1, .v2] {
            XCTAssertThrowsError(try h.store(version).open()) { XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema) }
        }
    }

    func testEmptyV3StartupStillProtectsTheOriginalAndDoesNotAddCards() async throws {
        let opened = try await coordinator().open()
        XCTAssertEqual(opened.schemaVersion, .v3)
        XCTAssertEqual(try h.capture(opened).counts.total, 0)
        let inventory = try await h.vault.inventory()
        XCTAssertEqual(inventory.snapshots.map(\.kind), [.beforeMigration])
        XCTAssertEqual(inventory.snapshots[0].counts.total, 0)
        XCTAssertFalse(opened.analysisRequiresResume)
    }

    func testBackupFailureRequiresExplicitRetryAndKeepsV2WritesBlocked() async throws {
        let original = try V3TestSupport.source()
        let source = try await h.seed(.v2(original))
        for step in [WordNoteBackupVault.Checkpoint.snapshotWrite, .catalogWrite] {
            let vault = WordNoteBackupVault(directoryURL: h.vault.directoryURL) { if $0 == step { throw POSIXError(.ENOSPC) } }
            let failed = coordinator(vault: vault)
            do { _ = try await failed.open(retryMigration: true); XCTFail("Expected backup IO failure.") }
            catch { XCTAssertEqual(error as? POSIXError, POSIXError(.ENOSPC)) }
            XCTAssertEqual(failed.phase, .recoveryRequired)
            XCTAssertNil(failed.session)
            let blocked = try XCTUnwrap(failed.sourceSession)
            XCTAssertTrue(WordNoteWriteGate.isBlocked(blocked.container.mainContext))
            let writer = try WordNoteV2ContentService(container: blocked.container)
            XCTAssertThrowsError(try writer.capture(.init(rawText: "blocked migration write")))
            XCTAssertFalse(blocked.container.mainContext.autosaveEnabled)
            let reopened = try h.store.open()
            XCTAssertEqual(reopened.generation, source.generation)
            XCTAssertEqual(reopened.recoveryRequired, .migration)
            XCTAssertTrue(reopened.analysisRequiresResume)
            XCTAssertNil(try h.store.preparedGeneration(for: source.generation))
            XCTAssertThrowsError(try h.store.authorizeAnalysisResume(for: source.generation)) {
                XCTAssertEqual($0 as? WordNoteRestoreError, .migrationIncomplete)
            }
            do { _ = try await coordinator().open(); XCTFail("Must not retry automatically.") }
            catch { XCTAssertEqual(error as? WordNoteStartupMigrationError, .recoveryRequired) }
        }
        let retried = try await coordinator().open(retryMigration: true)
        XCTAssertEqual(retried.schemaVersion, .v3)
        XCTAssertEqual(try h.capture(source), .v2(original.canonicalized))
    }

    func testLegacyClozePreflightFailureRetainsSourceProtectionAndActionableIDs() async throws {
        var payload = try V3TestSupport.source()
        for i in payload.content.reviewEvents.indices { payload.content.reviewEvents[i].modeRaw = ReviewMode.contextCloze.rawValue }
        let source = try await h.seed(.v2(payload))
        let expectedIssues = try WordNoteV2ToV3Migration.preflight(payload)
        XCTAssertFalse(expectedIssues.isEmpty)
        let failed = coordinator()
        do { _ = try await failed.open(); XCTFail("Cloze history without a target must not be silently converted.") }
        catch { XCTAssertEqual(error as? WordNoteV2ToV3Migration.MigrationError, .preflightFailed(expectedIssues)) }
        XCTAssertEqual(failed.cardMigrationIssues, expectedIssues)
        XCTAssertTrue(try XCTUnwrap(failed.errorMessage).contains("saved answer range"))
        XCTAssertEqual(failed.phase, .recoveryRequired)
        XCTAssertNil(failed.session)
        XCTAssertEqual(try h.capture(h.store.open()), .v2(payload.canonicalized))
        XCTAssertNil(try h.store.preparedGeneration(for: source.generation))
        let protection = try XCTUnwrap(failed.protectionBackup)
        let verified = try await h.vault.readVersionedSnapshot(id: protection.id)
        XCTAssertEqual(verified.payload, .v2(payload.canonicalized))
        do { _ = try await coordinator().open(); XCTFail("Blocked migration needs explicit recovery.") }
        catch { XCTAssertEqual(error as? WordNoteStartupMigrationError, .recoveryRequired) }
    }

    func testProtectionTimestampTamperingIsRejectedBeforeItCanBecomeMigrationTime() async throws {
        let original = try V3TestSupport.source()
        let source = try await h.seed(.v2(original))
        let directory = h.vault.directoryURL
        let tampering = WordNoteBackupVault(directoryURL: directory) { checkpoint in
            guard checkpoint == .catalogWrite else { return }
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasSuffix(".wordnote-backup.json") {
                guard case .v2(let decoded) = try WordNoteSnapshotReader.decode(Data(contentsOf: url)),
                      decoded.document.kind == .beforeMigration else { continue }
                var document = decoded.document
                document.createdAt = document.createdAt.addingTimeInterval(1)
                try PrivateFileIO.write(JSONEncoder().encode(document), to: url)
            }
        }
        let failed = coordinator(vault: tampering)
        do { _ = try await failed.open(); XCTFail("Migration timestamp must come from the exact verified protection.") }
        catch { XCTAssertEqual(error as? WordNoteStartupMigrationError, .protectionMismatch) }
        XCTAssertNil(try h.store.preparedGeneration(for: source.generation))
        XCTAssertEqual(try h.capture(h.store.open()), .v2(original.canonicalized))
        XCTAssertEqual(failed.phase, .recoveryRequired)
    }

    func testPreparedMigrationCompletesOnRestartWithoutCreatingANewBackup() async throws {
        let original = try V3TestSupport.source()
        let source = try await h.seed(.v2(original))
        let prepared = try await prepare(source)
        let before = try await h.vault.inventory()
        let restarted = try await coordinator().open()
        XCTAssertEqual(restarted.generation, prepared.generation)
        XCTAssertEqual(restarted.restoreOutcome, .migrated)
        let after = try await h.vault.inventory()
        XCTAssertEqual(after.snapshots, before.snapshots)
        XCTAssertEqual(try h.capture(source), .v2(original.canonicalized))
    }

    func testActivationFailureOrInterruptedActivationRequiresExplicitMigrationRetry() async throws {
        let original = try V3TestSupport.source()
        let source = try await h.seed(.v2(original))
        for step in [WordNoteRestoreStore.Checkpoint.activateJournal, .commitJournal] {
            let failedStore = WordNoteRestoreStore(directoryURL: h.directory, targetSchema: .v3) { if $0 == step { throw POSIXError(.ENOSPC) } }
            do { _ = try await coordinator(store: failedStore).open(retryMigration: true); XCTFail("Failed activation must not be ready.") }
            catch { XCTAssertEqual(error as? WordNoteStartupMigrationError, .recoveryRequired) }
            let retained = try h.store.open()
            XCTAssertEqual(retained.recoveryRequired, .migration)
            XCTAssertEqual(retained.generation, source.generation)
            XCTAssertEqual(try h.capture(retained), .v2(original.canonicalized))
        }
        _ = try await prepare(source)
        var journal = try h.journal()
        var pending = try XCTUnwrap(journal["pending"] as? [String: Any])
        pending["phase"] = "activating"
        journal["pending"] = pending
        try h.writeJournal(journal)
        for _ in 0..<2 {
            do { _ = try await coordinator().open(); XCTFail("Uncertain activation must not automatically retry.") }
            catch { XCTAssertEqual(error as? WordNoteStartupMigrationError, .recoveryRequired) }
        }
        let retried = try await coordinator().open(retryMigration: true)
        XCTAssertEqual(retried.schemaVersion, .v3)
        XCTAssertEqual(try h.capture(source), .v2(original.canonicalized))
    }

    func testCancelledMigrationNeverPublishesSessionOrUnblocksSourceWriters() async throws {
        let original = try V3TestSupport.source()
        let source = try await h.seed(.v2(original))
        let checkpoint = BlockingRestoreCheckpoint()
        let failed = coordinator(store: h.blockingStore(checkpoint))
        let task = Task { try await failed.open() }
        await h.waitForCheckpoint(checkpoint)
        XCTAssertEqual(failed.phase, .staging)
        XCTAssertFalse(checkpoint.wasOnMainThread)
        let blocked = try XCTUnwrap(failed.sourceSession)
        task.cancel()
        checkpoint.release()
        do { _ = try await task.value; XCTFail("Cancelled migration must stop.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(WordNoteWriteGate.isBlocked(blocked.container.mainContext))
        XCTAssertEqual(failed.phase, .recoveryRequired)
        XCTAssertNil(failed.session)
        XCTAssertNil(try h.store.preparedGeneration(for: source.generation))
        XCTAssertEqual(try h.capture(h.store.open()), .v2(original.canonicalized))
    }

    func testSourceEditDuringStagingCancelsOwnCopyAndRetainsTheNewSourceData() async throws {
        let original = try V3TestSupport.source()
        let source = try await h.seed(.v2(original))
        let checkpoint = BlockingRestoreCheckpoint()
        let failed = coordinator(store: h.blockingStore(checkpoint))
        let task = Task { try await failed.open() }
        await h.waitForCheckpoint(checkpoint)
        let blocked = try XCTUnwrap(failed.sourceSession)
        let term = try XCTUnwrap(blocked.container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV2.TermModel>()).first)
        term.chineseMeaning = "Synthetic concurrent change"
        try blocked.container.mainContext.save()
        let latest = try h.capture(blocked)
        checkpoint.release()
        do { _ = try await task.value; XCTFail("Changed source must stop the switch.") }
        catch { XCTAssertEqual(error as? WordNoteStartupMigrationError, .sourceChanged) }
        XCTAssertNil(try h.store.preparedGeneration(for: source.generation))
        XCTAssertEqual(try h.capture(h.store.open()), latest)
        let next = coordinator()
        let retried = try await next.open(retryMigration: true)
        guard case .v2(let changed) = latest else { return XCTFail("Expected V2 source.") }
        let expected = try WordNoteV2ToV3Migration.convert(changed, at: XCTUnwrap(next.protectionBackup).createdAt)
        XCTAssertEqual(try h.capture(retried), .v3(expected))
    }

    func testMigrationFailureCannotCancelAnotherPreparedGeneration() async throws {
        let source = try await h.seed(.v2(try V3TestSupport.source()))
        let checkpoint = BlockingRestoreCheckpoint()
        let first = coordinator(store: h.blockingStore(checkpoint))
        let task = Task { try await first.open() }
        await h.waitForCheckpoint(checkpoint)
        let backup = try XCTUnwrap(first.protectionBackup)
        let verified = try await h.vault.readVersionedSnapshot(id: backup.id)
        let winner = try await h.store.prepareMigration(verified, replacing: source.generation)
        checkpoint.release()
        do { _ = try await task.value; XCTFail("Late stage must not publish.") }
        catch { XCTAssertEqual(error as? WordNoteRestoreError, .restoreAlreadyPending) }
        XCTAssertEqual(try h.store.preparedGeneration(for: source.generation), winner.generation)
        let activated = try await coordinator().open()
        XCTAssertEqual(activated.generation, winner.generation)
    }

    func testCorruptExistingV3DataIsNotExposedAsReadyOrRepairedByV2RepairService() async throws {
        let source = try await h.seed(.v3(try V3TestSupport.reviewedPayload()))
        let item = try XCTUnwrap(source.container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewSessionItemModel>()).first)
        item.sessionID = UUID()
        try source.container.mainContext.save()
        let failed = coordinator()
        do { _ = try await failed.open(); XCTFail("Invalid session graph must block startup.") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotError, .invalidValue) }
        XCTAssertNil(failed.session)
        XCTAssertEqual(failed.phase, .recoveryRequired)
        do { _ = try await failed.inspectRepair(); XCTFail("V2 repair must not discard V3 entities.") }
        catch { XCTAssertEqual(error as? WordNoteStartupMigrationError, .repairUnavailable) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.storeURL.path))
        XCTAssertEqual(try h.store.open().generation, source.generation)
    }

    func testMissingMigrationSourceIsNotRecreatedAsEmpty() async throws {
        let source = try await h.seed(.v2(try V3TestSupport.source()))
        try h.store.beginMigration(replacing: source.generation)
        let before = try await h.vault.inventory()
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: source.storeURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        do { _ = try await coordinator().open(retryMigration: true); XCTFail("Missing source must not become empty V3.") }
        catch { XCTAssertEqual(error as? WordNoteRestoreError, .missingStore) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.storeURL.path))
        let after = try await h.vault.inventory()
        XCTAssertEqual(after.snapshots, before.snapshots)
    }

    private func coordinator(store: WordNoteRestoreStore? = nil, vault: WordNoteBackupVault? = nil) -> WordNoteStartupCoordinator {
        let preferences = h.preferences
        return .init(store: store ?? h.store, vault: vault ?? h.vault, preferences: { preferences })
    }

    private func prepare(_ source: WordNoteStoreSession) async throws -> WordNotePreparedStore {
        try h.store.beginMigration(replacing: source.generation)
        let saved = try await h.vault.create(h.capture(source), kind: .beforeMigration, now: V3TestSupport.date)
        let verified = try await h.vault.readVersionedSnapshot(id: saved.snapshot.id)
        return try await h.store.prepareMigration(verified, replacing: source.generation)
    }
}
