import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteVersionedRestoreStoreTests: XCTestCase {
    private var directory: URL!
    private typealias Support = WordNoteV2ServiceTestSupport

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "versioned-restore-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testVersionedOpenDoesNotImplicitlyMigrateLegacyStoreOrCreateJournal() throws {
        let original = try originalPayload()
        let session = try store.open()
        XCTAssertEqual(session.schemaVersion, .v1)
        XCTAssertEqual(session.generation, .legacy)
        XCTAssertEqual(try captured(session), .v1(original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testLegacyPreparedJournalStillOpensAsV1WithOriginalCountsFormat() async throws {
        let original = try originalPayload()
        let source = try WordNoteSnapshotCodec.decode(WordNoteSnapshotCodec.encode(original, kind: .manual))
        _ = try await legacyStore.prepareRestore(source, replacing: .legacy, protectedBy: protection(.v1(original)))
        let journal = try journalObject()
        let pending = try XCTUnwrap(journal["pending"] as? [String: Any])
        XCTAssertEqual(journal["version"] as? Int, 1)
        XCTAssertNil(journal["activeSchemaVersion"])
        XCTAssertNil(pending["schemaVersion"])
        XCTAssertEqual((pending["counts"] as? [String: Any])?.count, 5)
        let opened = try store.open()
        XCTAssertEqual(opened.schemaVersion, .v1)
        XCTAssertEqual(opened.restoreOutcome, .restored)
        XCTAssertEqual(try captured(opened), .v1(original))
        XCTAssertEqual(try legacyStore.open().generation, opened.generation)
    }

    func testV2RestoreSwitchesOnlyOnNextOpenAndKeepsAllEightEntities() async throws {
        let original = try originalPayload()
        let snapshot = try v2Snapshot()
        let generation = try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: protection(.v1(original)))
        let prepared = try journalObject()
        let pending = try XCTUnwrap(prepared["pending"] as? [String: Any])
        XCTAssertEqual(prepared["version"] as? Int, 2)
        XCTAssertEqual(prepared["activeSchemaVersion"] as? String, "1.0.0")
        XCTAssertEqual(pending["schemaVersion"] as? String, "2.0.0")
        XCTAssertEqual((pending["counts"] as? [String: Any])?.count, 8)
        XCTAssertEqual(try legacyPayload(), original)
        let restored = try store.open()
        XCTAssertEqual(restored.generation, generation)
        XCTAssertEqual(restored.schemaVersion, .v2)
        XCTAssertEqual(restored.restoreOutcome, .restored)
        XCTAssertEqual(try captured(restored, preferences: snapshot.payload.preferences), snapshot.payload.canonicalized)
        XCTAssertEqual(try legacyPayload(), original)
        let committed = try journalObject()
        XCTAssertEqual(committed["previousSchemaVersion"] as? String, "1.0.0")
        let reopened = try store.open()
        XCTAssertEqual(reopened.schemaVersion, .v2)
        XCTAssertEqual(reopened.restoreOutcome, .none)
        XCTAssertEqual(reopened.generation, generation)
        XCTAssertEqual(try captured(reopened, preferences: snapshot.payload.preferences), snapshot.payload.canonicalized)
    }

    func testLegacyEntryPointsRejectV2JournalBeforeChangingItOrEitherStore() async throws {
        let original = try originalPayload()
        let snapshot = try v2Snapshot()
        let backup = try await protection(.v1(original))
        await assertThrowsAsync({ try await legacyStore.prepareRestore(snapshot, replacing: .legacy, protectedBy: backup) }) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        _ = try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: backup)
        for activated in [false, true] {
            let generation = activated ? try store.open().generation : .legacy
            let before = try Data(contentsOf: journalURL)
            for operation in [
                { _ = try self.legacyStore.open() },
                { try self.legacyStore.cancelPreparedRestore(replacing: generation) },
                { try self.legacyStore.requireAnalysisPause(for: generation) },
                { try self.legacyStore.authorizeAnalysisResume(for: generation) },
                { try self.legacyStore.acknowledgePreferences(for: generation) }
            ] {
                XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema) }
                XCTAssertEqual(try Data(contentsOf: journalURL), before)
                XCTAssertEqual(try legacyPayload(), original)
            }
        }
        XCTAssertEqual(try captured(store.open(), preferences: snapshot.payload.preferences), snapshot.payload.canonicalized)
    }

    func testV1SnapshotIsUpgradedWhenRestoringIntoV2Runtime() async throws {
        let original = try originalPayload()
        let snapshot = try WordNoteSnapshotCodec.decode(WordNoteSnapshotCodec.encode(original, kind: .manual))
        let expected = try WordNoteV1ToV2Migration.convert(original).payload
        _ = try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: protection(.v1(original)))
        let restored = try store.open()
        XCTAssertEqual(restored.schemaVersion, .v2)
        XCTAssertEqual(try captured(restored), .v2(expected))
        XCTAssertEqual(try legacyPayload(), original)
        XCTAssertEqual(expected.content.terms.map(\.id), original.terms.map(\.id))
        XCTAssertEqual(expected.content.reviewEvents, original.reviewEvents)
    }

    func testSecondRestoreUsesActiveV2ProtectionAndNeverDowngradesOldSnapshot() async throws {
        let original = try originalPayload()
        let snapshot = try v2Snapshot()
        _ = try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: protection(.v1(original)))
        let first = try store.open()
        let old = try WordNoteSnapshotCodec.decode(WordNoteSnapshotCodec.encode(original, kind: .manual))
        await assertThrowsAsync({ try await store.prepareRestore(old, replacing: first.generation, protectedBy: protection(.v1(original))) }) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .protectionRequired)
        }
        let second = try await store.prepareRestore(old, replacing: first.generation, protectedBy: protection(snapshot.payload))
        XCTAssertNotEqual(second, first.generation)
        let restored = try store.open()
        XCTAssertEqual(restored.schemaVersion, .v2)
        XCTAssertEqual(try captured(restored), .v2(try WordNoteV1ToV2Migration.convert(original).payload))
        XCTAssertEqual(try captured(first, preferences: snapshot.payload.preferences), snapshot.payload.canonicalized)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.storeURL.path))
        XCTAssertEqual((try journalObject())["previousSchemaVersion"] as? String, "2.0.0")
    }

    func testQueuedWorkAndPreferencesStayPausedUntilExplicitAcknowledgment() async throws {
        let original = try originalPayload()
        let snapshot = try v2Snapshot()
        _ = try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: protection(.v1(original)))
        let restored = try store.open()
        XCTAssertTrue(restored.analysisRequiresResume)
        XCTAssertEqual(restored.preferencesToApply, snapshot.payload.preferences)
        XCTAssertTrue(try store.open().analysisRequiresResume)
        try store.acknowledgePreferences(for: restored.generation)
        try store.authorizeAnalysisResume(for: restored.generation)
        let acknowledged = try store.open()
        XCTAssertFalse(acknowledged.analysisRequiresResume)
        XCTAssertNil(acknowledged.preferencesToApply)
        XCTAssertEqual(try captured(acknowledged, preferences: snapshot.payload.preferences), snapshot.payload.canonicalized)
    }

    func testV2ResumeDetectionIncludesQueuedRunningAndFailedButNotInactiveWork() throws {
        let container = try Support.container(populated: false)
        defer { withExtendedLifetime(container) {} }
        _ = try WordNoteV2ContentService(container: container).capture(.init(rawText: "pending word"), at: Support.now)
        var payload = try Support.snapshot(container)
        for (state, expected) in [("queued", true), ("running", true), ("failed", true), ("cancelled", false), ("none", false)] {
            payload.recordStates[0].queueStateRaw = state
            payload.recordStates[0].attemptID = state == "running" ? UUID() : nil
            try payload.validate()
            XCTAssertEqual(WordNoteVersionedPayload.v2(payload).requiresAnalysisResume, expected, state)
        }
    }

    func testStagingAndPreparationFailuresNeverSelectV2OrChangeOriginal() async throws {
        let original = try originalPayload()
        let snapshot = try v2Snapshot()
        let backup = try await protection(.v1(original))
        for failure in [WordNoteRestoreStore.Checkpoint.stagingSaved, .prepareJournal] {
            let failing = WordNoteRestoreStore(directoryURL: directory, targetSchema: .v2) { step in
                if step == failure { throw POSIXError(.ENOSPC) }
            }
            await assertThrowsAsync({ try await failing.prepareRestore(snapshot, replacing: .legacy, protectedBy: backup) }) {
                XCTAssertEqual($0 as? POSIXError, POSIXError(.ENOSPC))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
            XCTAssertEqual(try captured(legacyStore.open()), .v1(original))
        }
    }

    func testActivationAndCommitFailuresReturnToCorrectV1Schema() async throws {
        let original = try originalPayload()
        let snapshot = try v2Snapshot()
        let backup = try await protection(.v1(original))
        for failure in [WordNoteRestoreStore.Checkpoint.activateJournal, .commitJournal] {
            _ = try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: backup)
            let failing = WordNoteRestoreStore(directoryURL: directory, targetSchema: .v2) { step in
                if step == failure { throw POSIXError(.ENOSPC) }
            }
            let rolledBack = try failing.open()
            XCTAssertEqual(rolledBack.restoreOutcome, .rolledBack)
            XCTAssertEqual(rolledBack.schemaVersion, .v1)
            XCTAssertEqual(rolledBack.generation, .legacy)
            XCTAssertEqual(try captured(rolledBack), .v1(original))
            XCTAssertFalse(try store.hasPreparedRestore(for: .legacy))
        }
    }

    func testInterruptedActivationReturnsToActiveV2WithoutRetryingPending() async throws {
        let original = try originalPayload()
        let snapshot = try v2Snapshot()
        _ = try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: protection(.v1(original)))
        let first = try store.open()
        _ = try await store.prepareRestore(snapshot, replacing: first.generation, protectedBy: protection(snapshot.payload))
        var journal = try journalObject()
        var pending = try XCTUnwrap(journal["pending"] as? [String: Any])
        pending["phase"] = "activating"
        journal["pending"] = pending
        try writeJournal(journal)
        let recovered = try store.open()
        XCTAssertEqual(recovered.restoreOutcome, .rolledBack)
        XCTAssertEqual(recovered.schemaVersion, .v2)
        XCTAssertEqual(recovered.generation, first.generation)
        XCTAssertEqual(try captured(recovered, preferences: snapshot.payload.preferences), snapshot.payload.canonicalized)
        XCTAssertFalse(try store.hasPreparedRestore(for: first.generation))
        XCTAssertEqual(try store.open().recoveryRequired, .restore)
        XCTAssertTrue(try store.open().analysisRequiresResume)
        try store.authorizeAnalysisResume(for: first.generation)
        XCTAssertNil(try store.open().recoveryRequired)
        XCTAssertFalse(try store.open().analysisRequiresResume)
    }

    func testChangedV2OnlyRelationshipFailsChecksumAndRollsBack() async throws {
        let original = try originalPayload()
        let snapshot = try v2Snapshot()
        let generation = try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: protection(.v1(original)))
        try autoreleasepool {
            let schema = Schema(versionedSchema: WordNoteSchemaV2.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("WordNote", schema: schema, url: generationURL(generation))])
            let occurrence = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV2.TermOccurrenceModel>()).first)
            occurrence.note = "Changed only after staged verification"
            try container.mainContext.save()
        }
        let recovered = try store.open()
        XCTAssertEqual(recovered.restoreOutcome, .rolledBack)
        XCTAssertEqual(try captured(recovered), .v1(original))
    }

    func testMismatchInNewEntityCountPreventsActivation() async throws {
        let original = try originalPayload()
        _ = try await store.prepareRestore(v2Snapshot(), replacing: .legacy, protectedBy: protection(.v1(original)))
        var journal = try journalObject()
        var pending = try XCTUnwrap(journal["pending"] as? [String: Any])
        var counts = try XCTUnwrap(pending["counts"] as? [String: Any])
        counts["lookupEvents"] = try XCTUnwrap(counts["lookupEvents"] as? Int) + 1
        pending["counts"] = counts
        journal["pending"] = pending
        try writeJournal(journal)
        let recovered = try store.open()
        XCTAssertEqual(recovered.restoreOutcome, .rolledBack)
        XCTAssertEqual(try captured(recovered), .v1(original))
    }

    func testMissingAndSymlinkedV2StagingNeverCreateOrOpenReplacement() async throws {
        let original = try originalPayload()
        let snapshot = try v2Snapshot()
        let backup = try await protection(.v1(original))
        for symlink in [false, true] {
            let generation = try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: backup)
            let stagedDirectory = generationURL(generation).deletingLastPathComponent()
            try FileManager.default.removeItem(at: stagedDirectory)
            if symlink { try FileManager.default.createSymbolicLink(at: stagedDirectory, withDestinationURL: directory) }
            let recovered = try store.open()
            XCTAssertEqual(recovered.restoreOutcome, .rolledBack)
            XCTAssertEqual(try captured(recovered), .v1(original))
            if !symlink { XCTAssertFalse(FileManager.default.fileExists(atPath: generationURL(generation).path)) }
        }
    }

    func testMalformedVersionedJournalFailsWithoutChangingFiles() async throws {
        let original = try originalPayload()
        _ = try await store.prepareRestore(v2Snapshot(), replacing: .legacy, protectedBy: protection(.v1(original)))
        let valid = try journalObject()
        var variants: [[String: Any]] = []
        var missingSchema = valid
        missingSchema.removeValue(forKey: "activeSchemaVersion")
        variants.append(missingSchema)
        var unknownSchema = valid
        unknownSchema["activeSchemaVersion"] = "99.0.0"
        variants.append(unknownSchema)
        var legacyMarkedV2 = valid
        legacyMarkedV2["activeSchemaVersion"] = "2.0.0"
        variants.append(legacyMarkedV2)
        var missingCount = valid
        var pending = try XCTUnwrap(valid["pending"] as? [String: Any])
        var counts = try XCTUnwrap(pending["counts"] as? [String: Any])
        counts.removeValue(forKey: "lookupEvents")
        pending["counts"] = counts
        missingCount["pending"] = pending
        variants.append(missingCount)
        var negativeCount = valid
        counts["lookupEvents"] = -1
        pending["counts"] = counts
        negativeCount["pending"] = pending
        variants.append(negativeCount)
        var downgradedHeader = valid
        downgradedHeader["version"] = 1
        variants.append(downgradedHeader)
        var downgradedPending = valid
        pending = try XCTUnwrap(valid["pending"] as? [String: Any])
        counts = try XCTUnwrap(pending["counts"] as? [String: Any])
        for field in ["occurrences", "courseLinks", "lookupEvents"] { counts[field] = 0 }
        pending["schemaVersion"] = "1.0.0"
        pending["counts"] = counts
        downgradedPending["pending"] = pending
        variants.append(downgradedPending)
        for value in variants {
            try writeJournal(value)
            let bytes = try Data(contentsOf: journalURL)
            XCTAssertThrowsError(try store.open()) { XCTAssertEqual($0 as? WordNoteRestoreError, .invalidJournal) }
            XCTAssertEqual(try Data(contentsOf: journalURL), bytes)
            XCTAssertEqual(try legacyPayload(), original)
        }
    }

    func testCancelPreparedV2RetainsOriginalPauseAndVersionedGuard() async throws {
        let original = try originalPayload()
        try store.requireAnalysisPause(for: .legacy)
        _ = try await store.prepareRestore(v2Snapshot(), replacing: .legacy, protectedBy: protection(.v1(original)))
        try store.cancelPreparedRestore(replacing: .legacy)
        let reopened = try store.open()
        XCTAssertEqual(reopened.generation, .legacy)
        XCTAssertEqual(reopened.schemaVersion, .v1)
        XCTAssertTrue(reopened.analysisRequiresResume)
        XCTAssertEqual(try captured(reopened), .v1(original))
        XCTAssertEqual((try journalObject())["version"] as? Int, 2)
        XCTAssertThrowsError(try legacyStore.open()) { XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema) }
    }

    func testCancelledBackgroundV2StagingDoesNotPrepareJournal() async throws {
        let original = try originalPayload()
        let snapshot = try v2Snapshot()
        let backup = try await protection(.v1(original))
        let checkpoint = BlockingRestoreCheckpoint()
        let background = blockingStore(checkpoint)
        let task = Task { try await background.prepareRestore(snapshot, replacing: .legacy, protectedBy: backup) }
        await waitForCheckpoint(checkpoint)
        XCTAssertFalse(checkpoint.wasOnMainThread)
        task.cancel()
        checkpoint.release()
        await assertThrowsAsync({ try await task.value }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertEqual(try captured(store.open()), .v1(original))
    }

    func testCompetingRestoreCannotOverwritePreparedVersionedGeneration() async throws {
        let original = try originalPayload()
        let snapshot = try v2Snapshot()
        let backup = try await protection(.v1(original))
        let checkpoint = BlockingRestoreCheckpoint()
        let background = blockingStore(checkpoint)
        let task = Task { try await background.prepareRestore(snapshot, replacing: .legacy, protectedBy: backup) }
        await waitForCheckpoint(checkpoint)
        let winner = try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: backup)
        checkpoint.release()
        await assertThrowsAsync({ try await task.value }) { XCTAssertEqual($0 as? WordNoteRestoreError, .restoreAlreadyPending) }
        XCTAssertEqual(try store.open().generation, winner)
    }

    func testBackgroundResultCannotReplaceAlreadyActivatedGeneration() async throws {
        let original = try originalPayload()
        let snapshot = try v2Snapshot()
        let backup = try await protection(.v1(original))
        let checkpoint = BlockingRestoreCheckpoint()
        let background = blockingStore(checkpoint)
        let task = Task { try await background.prepareRestore(snapshot, replacing: .legacy, protectedBy: backup) }
        await waitForCheckpoint(checkpoint)
        let winner = try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: backup)
        _ = try store.open()
        checkpoint.release()
        await assertThrowsAsync({ try await task.value }) { XCTAssertEqual($0 as? WordNoteRestoreError, .staleGeneration) }
        XCTAssertEqual(try store.open().generation, winner)
        XCTAssertFalse(try store.hasPreparedRestore(for: winner))
    }

    private var store: WordNoteRestoreStore { WordNoteRestoreStore(directoryURL: directory, targetSchema: .v2) }
    private var legacyStore: WordNoteRestoreStore { WordNoteRestoreStore(directoryURL: directory) }
    private var journalURL: URL { directory.appending(path: "store-generations.json") }

    private func originalPayload() throws -> WordNoteSnapshotPayload {
        try autoreleasepool {
            let session = try legacyStore.open()
            try WordNoteTestFixture.populated.populate(session.container.mainContext)
            return try WordNoteSnapshotPayload.capture(from: session.container.mainContext)
        }
    }

    private func legacyPayload() throws -> WordNoteSnapshotPayload {
        try autoreleasepool {
            let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("WordNote", schema: schema, url: directory.appending(path: "WordNote.store"))])
            return try withExtendedLifetime(container) { try WordNoteSnapshotPayload.capture(from: container.mainContext) }
        }
    }

    private func v2Snapshot() throws -> VersionedWordNoteSnapshot {
        let container = try Support.container()
        defer { withExtendedLifetime(container) {} }
        let service = try WordNoteV2ContentService(container: container)
        _ = try service.capture(.init(rawText: "quick", note: "Source for restore", capturedVia: .floatingQuickAdd), at: Support.now)
        _ = try service.capture(.init(rawText: "queued input for restore"), at: Support.now)
        var payload = try Support.snapshot(container)
        payload.content.preferences = .init(appearance: "dark", defaultSource: "paper")
        payload.occurrences[0].sourceTitle = "Synthetic source"
        payload.occurrences[0].sourceURL = "https://example.com/lesson"
        payload.occurrences[0].sourcePage = "2"
        return try WordNoteSnapshotReader.decode(WordNoteSnapshotV2Codec.encode(payload, kind: .manual))
    }

    private func captured(
        _ session: WordNoteStoreSession, preferences: WordNoteSnapshotPayload.Preferences = .init()
    ) throws -> WordNoteVersionedPayload {
        try WordNoteVersionedPayload.capture(from: session.container.mainContext, preferences: preferences)
    }

    private func protection(_ payload: WordNoteVersionedPayload) async throws -> WordNoteBackupSummary {
        try await WordNoteBackupVault(directoryURL: directory.appending(path: "Backups")).create(payload, kind: .beforeRestore).snapshot
    }

    private func generationURL(_ generation: WordNoteStoreGeneration) -> URL {
        directory.appending(path: "Stores/\(generation.id!.uuidString.lowercased())/WordNote.store")
    }

    private func journalObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
    }

    private func writeJournal(_ value: [String: Any]) throws {
        try PrivateFileIO.write(JSONSerialization.data(withJSONObject: value), to: journalURL)
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
        XCTFail("Background staging did not reach its checkpoint.")
    }

    private func assertThrowsAsync<T>(
        _ operation: () async throws -> T, verify: (Error) -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do { _ = try await operation(); XCTFail("Expected failure.", file: file, line: line) }
        catch { verify(error) }
    }
}
