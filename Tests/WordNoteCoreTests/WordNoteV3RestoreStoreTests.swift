import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3RestoreStoreTests: XCTestCase {
    private var h: V3RecoveryHarness!

    override func setUp() async throws { h = V3RecoveryHarness(directory: try V3TestSupport.directory()) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: h.directory); h = nil }

    func testV3RestoreKeepsFullSessionAndProtectsPreviousV2Generation() async throws {
        let old = try V3TestSupport.source()
        let source = try await h.seed(.v2(old))
        let payload = try V3TestSupport.reviewedPayload()
        let backup = try await h.protection(.v2(old))
        let prepared = try await h.store.prepareRestore(h.snapshot(.v3(payload)), replacing: source.generation, protectedBy: backup)
        let journal = try h.journal()
        XCTAssertEqual(journal["version"] as? Int, 3)
        let pending = try XCTUnwrap(journal["pending"] as? [String: Any])
        XCTAssertEqual(pending["schemaVersion"] as? String, "3.0.0")
        XCTAssertEqual((pending["counts"] as? [String: Any])?.count, 11)
        for version in [WordNoteDataSchemaVersion.v1, .v2] {
            XCTAssertThrowsError(try h.store(version).open()) { XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema) }
        }
        let next = try h.store.open()
        XCTAssertEqual(next.schemaVersion, .v3)
        XCTAssertEqual(next.generation, prepared)
        XCTAssertEqual(next.restoreOutcome, .restored)
        XCTAssertEqual(next.preferencesToApply, payload.content.content.preferences)
        XCTAssertEqual(try h.capture(next), .v3(payload.canonicalized))
        XCTAssertEqual(try h.capture(source), .v2(old.canonicalized))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.storeURL.path))
        let reopened = try h.store.open()
        XCTAssertEqual(reopened.restoreOutcome, .none)
        XCTAssertEqual(try h.capture(reopened), .v3(payload.canonicalized))
        let saved = try await h.vault.readVersionedSnapshot(id: backup.id)
        XCTAssertEqual(saved.payload, .v2(old.canonicalized))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: next.storeURL.path)[.posixPermissions] as? Int, 0o600)
    }

    func testV3RestoreKeepsDeletedCardIdentityAndClozeTargets() async throws {
        var deleted = try V3TestSupport.reviewedPayload()
        let id = deleted.sessionItems[0].originalCardID
        deleted.cards.removeAll { $0.id == id }
        for i in deleted.eventStates.indices where deleted.eventStates[i].cardID == id { deleted.eventStates[i].cardID = nil }
        deleted.sessionItems[0].cardID = nil
        deleted.sessionItems[0].status = .unavailable
        deleted.sessionItems[0].completionOutcome = .unavailable
        deleted.sessionItems[0].availableAt = nil
        deleted.sessions[0].status = .completed
        deleted.sessions[0].endedAt = V3TestSupport.date
        var active = try V3TestSupport.reviewedPayload()
        active.sessionItems[0].status = .presented
        active.sessionItems[0].availableAt = nil
        active.sessions[0].status = .active
        active.sessions[0].currentItemID = active.sessionItems[0].id
        var source = try await h.seed(.v3(try V3TestSupport.payload()))
        for payload in [deleted, try V3TestSupport.clozePayload(), active] {
            let original = try h.capture(source)
            let backup = try await h.protection(original)
            _ = try await h.store.prepareRestore(h.snapshot(.v3(payload)), replacing: source.generation, protectedBy: backup)
            source = try h.store.open()
            XCTAssertEqual(try h.capture(source), .v3(payload.canonicalized))
        }
    }

    func testRestoringOldBackupIntoV3UsesProtectionTimestampAndNeverDowngrades() async throws {
        var source = try await h.seed(.v3(try V3TestSupport.reviewedPayload()))
        let v2 = try V3TestSupport.source()
        for legacy in [WordNoteVersionedPayload.v1(v2.content), .v2(v2)] {
            let backup = try await h.protection(h.capture(source))
            let snapshot = try h.snapshot(legacy, at: V3TestSupport.date.addingTimeInterval(-86_400))
            _ = try await h.store.prepareRestore(snapshot, replacing: source.generation, protectedBy: backup)
            source = try h.store.open()
            let convertedV2: WordNoteSnapshotV2Payload
            if case .v1(let value) = legacy { convertedV2 = try WordNoteV1ToV2Migration.convert(value).payload }
            else { convertedV2 = v2 }
            let expected = try WordNoteV2ToV3Migration.convert(convertedV2, at: backup.createdAt)
            XCTAssertEqual(source.schemaVersion, .v3)
            XCTAssertEqual(try h.capture(source), .v3(expected))
            XCTAssertEqual(expected.cards.count, convertedV2.content.terms.count)
            XCTAssertTrue(expected.sessions.isEmpty)
            XCTAssertTrue(expected.cards.allSatisfy { $0.createdAt == backup.createdAt })
        }
    }

    func testV3TargetOpenDoesNotMigrateUntilExplicitStartup() async throws {
        let payload = try V3TestSupport.source()
        let original = try await h.seed(.v2(payload))
        let bytes = try Data(contentsOf: h.journalURL)
        let opened = try h.store.open()
        XCTAssertEqual(opened.schemaVersion, .v2)
        XCTAssertEqual(opened.generation, original.generation)
        XCTAssertEqual(try h.capture(opened), .v2(payload.canonicalized))
        XCTAssertEqual(try Data(contentsOf: h.journalURL), bytes)
    }

    func testOldRestoreTargetsRejectV3BeforeStagingOrChangingJournal() async throws {
        let source = try await h.seed(.v2(try V3TestSupport.source()))
        let backup = try await h.protection(h.capture(source))
        let bytes = try Data(contentsOf: h.journalURL)
        let snapshot = try h.snapshot(.v3(V3TestSupport.reviewedPayload()))
        for target in [WordNoteDataSchemaVersion.v1, .v2] {
            do { _ = try await h.store(target).prepareRestore(snapshot, replacing: source.generation, protectedBy: backup); XCTFail("Must reject newer schema.") }
            catch { XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedSchema) }
            XCTAssertEqual(try Data(contentsOf: h.journalURL), bytes)
        }
    }

    func testCancelledV3PreparationKeepsVersionThreeAndOriginalStore() async throws {
        let source = try await h.seed(.v2(try V3TestSupport.source()))
        let old = try h.capture(source)
        let backup = try await h.protection(old)
        let prepared = try await h.store.prepareRestore(h.snapshot(.v3(V3TestSupport.reviewedPayload())), replacing: source.generation, protectedBy: backup)
        try h.store.cancelPreparedRestore(replacing: source.generation, expectedPending: prepared)
        XCTAssertEqual((try h.journal())["version"] as? Int, 3)
        XCTAssertNil(try h.store.preparedGeneration(for: source.generation))
        XCTAssertEqual(try h.capture(h.store.open()), old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.generationURL(prepared).path))
        XCTAssertThrowsError(try h.store(.v2).open()) { XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema) }
    }

    func testEveryNewJournalCountIsRequiredBoundedAndComparedAfterReopen() async throws {
        let source = try await h.seed(.v2(try V3TestSupport.source()))
        let old = try h.capture(source)
        let backup = try await h.protection(old)
        _ = try await h.store.prepareRestore(h.snapshot(.v3(V3TestSupport.reviewedPayload())), replacing: source.generation, protectedBy: backup)
        let valid = try h.journal()
        for field in ["cards", "sessions", "sessionItems"] {
            for value in [nil, -1, 100_001, Int.max] as [Int?] {
                var changed = valid
                var pending = try XCTUnwrap(valid["pending"] as? [String: Any])
                var counts = try XCTUnwrap(pending["counts"] as? [String: Any])
                counts[field] = value
                pending["counts"] = counts
                changed["pending"] = pending
                try h.writeJournal(changed)
                XCTAssertThrowsError(try h.store.open()) { XCTAssertEqual($0 as? WordNoteRestoreError, .invalidJournal) }
            }
            var changed = valid
            var pending = try XCTUnwrap(valid["pending"] as? [String: Any])
            var counts = try XCTUnwrap(pending["counts"] as? [String: Any])
            counts[field] = try XCTUnwrap(counts[field] as? Int) + 1
            pending["counts"] = counts
            changed["pending"] = pending
            try h.writeJournal(changed)
            let rolledBack = try h.store.open()
            XCTAssertEqual(rolledBack.restoreOutcome, .rolledBack)
            XCTAssertEqual(try h.capture(rolledBack), old)
        }
        try h.writeJournal(valid)
        XCTAssertEqual(try h.store.open().schemaVersion, .v3)
    }

    func testJournalCannotHideV3DataBehindAnOlderVersionOrSchema() async throws {
        let source = try await h.seed(.v2(try V3TestSupport.source()))
        let backup = try await h.protection(h.capture(source))
        _ = try await h.store.prepareRestore(h.snapshot(.v3(V3TestSupport.reviewedPayload())), replacing: source.generation, protectedBy: backup)
        let valid = try h.journal()
        for downgrade in [1, 2] {
            var changed = valid
            changed["version"] = downgrade
            try h.writeJournal(changed)
            XCTAssertThrowsError(try h.store.open()) { XCTAssertEqual($0 as? WordNoteRestoreError, .invalidJournal) }
        }
        for field in ["schemaVersion", "operation"] {
            var changed = valid
            var pending = try XCTUnwrap(valid["pending"] as? [String: Any])
            pending[field] = field == "schemaVersion" ? "2.0.0" : "repair"
            changed["pending"] = pending
            try h.writeJournal(changed)
            XCTAssertThrowsError(try h.store.open()) { XCTAssertEqual($0 as? WordNoteRestoreError, .invalidJournal) }
        }
        try h.writeJournal(valid)
    }

    func testInterruptedActivationAndCommitFailureKeepOriginalAndRequireRecovery() async throws {
        let source = try await h.seed(.v2(try V3TestSupport.source()))
        let old = try h.capture(source)
        let backup = try await h.protection(old)
        let snapshot = try h.snapshot(.v3(V3TestSupport.reviewedPayload()))
        for checkpoint in [WordNoteRestoreStore.Checkpoint.activateJournal, .commitJournal] {
            _ = try await h.store.prepareRestore(snapshot, replacing: source.generation, protectedBy: backup)
            let failed = WordNoteRestoreStore(directoryURL: h.directory, targetSchema: .v3) { if $0 == checkpoint { throw POSIXError(.ENOSPC) } }
            let rollback = try failed.open()
            XCTAssertEqual(rollback.generation, source.generation)
            XCTAssertEqual(rollback.restoreOutcome, .rolledBack)
            XCTAssertEqual(rollback.recoveryRequired, .restore)
            XCTAssertTrue(rollback.analysisRequiresResume)
            XCTAssertEqual(try h.capture(rollback), old)
        }
        _ = try await h.store.prepareRestore(snapshot, replacing: source.generation, protectedBy: backup)
        var changed = try h.journal()
        var pending = try XCTUnwrap(changed["pending"] as? [String: Any])
        pending["phase"] = "activating"
        changed["pending"] = pending
        try h.writeJournal(changed)
        let rollback = try h.store.open()
        XCTAssertEqual(rollback.restoreOutcome, .rolledBack)
        XCTAssertEqual(try h.capture(rollback), old)
        XCTAssertNil(try h.store.preparedGeneration(for: source.generation))
    }

    func testStagingAndPrepareJournalFailuresCannotSelectPartialV3Store() async throws {
        let source = try await h.seed(.v2(try V3TestSupport.source()))
        let original = try h.capture(source)
        let backup = try await h.protection(original)
        let before = try Data(contentsOf: h.journalURL)
        for checkpoint in [WordNoteRestoreStore.Checkpoint.stagingSaved, .prepareJournal] {
            let failed = WordNoteRestoreStore(directoryURL: h.directory, targetSchema: .v3) { if $0 == checkpoint { throw POSIXError(.ENOSPC) } }
            do { _ = try await failed.prepareRestore(h.snapshot(.v3(V3TestSupport.reviewedPayload())), replacing: source.generation, protectedBy: backup); XCTFail("Expected IO failure.") }
            catch { XCTAssertEqual(error as? POSIXError, POSIXError(.ENOSPC)) }
            XCTAssertEqual(try Data(contentsOf: h.journalURL), before)
            XCTAssertEqual(try h.capture(h.store.open()), original)
            XCTAssertNil(try h.store.preparedGeneration(for: source.generation))
        }
    }

    func testChangedCardInStagingIsDetectedByFullChecksum() async throws {
        let source = try await h.seed(.v2(try V3TestSupport.source()))
        let original = try h.capture(source)
        let backup = try await h.protection(original)
        let staged = try await h.store.prepareRestore(h.snapshot(.v3(V3TestSupport.reviewedPayload())), replacing: source.generation, protectedBy: backup)
        try autoreleasepool {
            let container = try V3TestSupport.container(url: h.generationURL(staged))
            let card = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewCardModel>()).first)
            card.revision += 1
            try container.mainContext.save()
        }
        let opened = try h.store.open()
        XCTAssertEqual(opened.restoreOutcome, .rolledBack)
        XCTAssertEqual(try h.capture(opened), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.generationURL(staged).path))
    }

    func testMissingCommittedV3StoreIsNotReplacedWithAnEmptyDatabase() async throws {
        let source = try await h.seed(.v3(try V3TestSupport.reviewedPayload()))
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: source.storeURL.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        XCTAssertThrowsError(try h.store.open()) { XCTAssertEqual($0 as? WordNoteRestoreError, .missingStore) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.storeURL.path))
    }

    func testCancelledBackgroundV3StageCannotPublishPendingGeneration() async throws {
        let source = try await h.seed(.v2(try V3TestSupport.source()))
        let original = try h.capture(source)
        let snapshot = try h.snapshot(.v3(V3TestSupport.reviewedPayload()))
        let backup = try await h.protection(original)
        let checkpoint = BlockingRestoreCheckpoint()
        let worker = h.blockingStore(checkpoint)
        let task = Task { try await worker.prepareRestore(snapshot, replacing: source.generation, protectedBy: backup) }
        await h.waitForCheckpoint(checkpoint)
        XCTAssertFalse(checkpoint.wasOnMainThread)
        task.cancel()
        checkpoint.release()
        do { _ = try await task.value; XCTFail("Cancellation must stop before publishing.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(try h.store.preparedGeneration(for: source.generation))
        XCTAssertEqual(try h.capture(h.store.open()), original)
    }

    func testBackgroundStageCannotOverwriteAnotherPreparedOrActivatedV3Generation() async throws {
        var source = try await h.seed(.v2(try V3TestSupport.source()))
        for activate in [false, true] {
            let generation = source.generation
            let snapshot = try h.snapshot(.v3(V3TestSupport.reviewedPayload()))
            let backup = try await h.protection(h.capture(source))
            let checkpoint = BlockingRestoreCheckpoint()
            let worker = h.blockingStore(checkpoint)
            let task = Task { try await worker.prepareRestore(snapshot, replacing: generation, protectedBy: backup) }
            await h.waitForCheckpoint(checkpoint)
            let winner = try await h.store.prepareRestore(snapshot, replacing: generation, protectedBy: backup)
            if activate { source = try h.store.open() }
            checkpoint.release()
            do { _ = try await task.value; XCTFail("Late stage must not replace the winner.") }
            catch { XCTAssertEqual(error as? WordNoteRestoreError, activate ? .staleGeneration : .restoreAlreadyPending) }
            source = try h.store.open()
            XCTAssertEqual(source.generation, winner)
        }
    }
}

@MainActor
final class V3RecoveryHarness {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    var store: WordNoteRestoreStore { store(.v3) }
    func store(_ schema: WordNoteDataSchemaVersion) -> WordNoteRestoreStore { .init(directoryURL: directory, targetSchema: schema) }
    var vault: WordNoteBackupVault { .init(directoryURL: directory.appending(path: "Backups")) }
    var journalURL: URL { directory.appending(path: "store-generations.json") }
    var preferences: WordNoteSnapshotPayload.Preferences { .init(appearance: "dark", defaultSource: "book") }

    func capture(_ session: WordNoteStoreSession) throws -> WordNoteVersionedPayload {
        try WordNoteVersionedPayload.capture(from: session.container.mainContext, preferences: session.preferencesToApply ?? preferences,
            learningPreferences: session.learningPreferencesToApply)
    }

    func seed(_ payload: WordNoteVersionedPayload) async throws -> WordNoteStoreSession {
        let source = try store(.v1).open()
        if case .v1(let legacy) = payload {
            try legacy.populateEmptyStore(source.container.mainContext)
            return source
        }
        let backup = try await protection(capture(source))
        let destination = store(payload.schemaVersion)
        _ = try await destination.prepareRestore(snapshot(payload), replacing: source.generation, protectedBy: backup)
        return try destination.open()
    }

    func snapshot(_ payload: WordNoteVersionedPayload, at date: Date = V3TestSupport.date) throws -> VersionedWordNoteSnapshot {
        try WordNoteSnapshotReader.decode(payload.encode(kind: .manual, createdAt: date))
    }

    func protection(_ payload: WordNoteVersionedPayload) async throws -> WordNoteBackupSummary {
        try await vault.create(payload, kind: .beforeRestore, now: V3TestSupport.date).snapshot
    }

    func journal() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
    }

    func writeJournal(_ value: [String: Any]) throws { try PrivateFileIO.write(JSONSerialization.data(withJSONObject: value), to: journalURL) }

    func generationURL(_ generation: WordNoteStoreGeneration) -> URL {
        directory.appending(path: "Stores/\(generation.id!.uuidString.lowercased())/WordNote.store")
    }

    func blockingStore(_ checkpoint: BlockingRestoreCheckpoint) -> WordNoteRestoreStore {
        .init(directoryURL: directory, targetSchema: .v3) { if $0 == .stagingSaved { try checkpoint.waitForRelease() } }
    }

    func waitForCheckpoint(_ checkpoint: BlockingRestoreCheckpoint) async {
        for _ in 0..<1_000 {
            if checkpoint.isWaiting { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        checkpoint.release()
        XCTFail("Staging did not reach its background checkpoint.")
    }
}
