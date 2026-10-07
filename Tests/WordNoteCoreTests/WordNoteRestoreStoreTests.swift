import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteRestoreStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "restore-store-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testNoManifestKeepsExistingLegacyStoreAndDoesNotCreateJournal() throws {
        let original = try originalPayload()
        let session = try store.open()
        XCTAssertEqual(session.generation, .legacy)
        XCTAssertEqual(session.storeURL, directory.appending(path: "WordNote.store"))
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: session.container.mainContext), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testRestoreSwitchesOnlyAtNextOpenAndRetainsOldStore() async throws {
        let original = try originalPayload()
        let replacement = try replacementSnapshot()
        let protection = try await protectedBackup(original)
        let generation = try await store.prepareRestore(replacement, replacing: .legacy, protectedBy: protection)
        XCTAssertNotEqual(generation, .legacy)
        XCTAssertEqual(try payload(at: directory.appending(path: "WordNote.store")), original)
        let restored = try store.open()
        XCTAssertEqual(restored.restoreOutcome, .restored)
        XCTAssertEqual(restored.generation, generation)
        XCTAssertEqual(restored.preferencesToApply, replacement.payload.preferences)
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: restored.container.mainContext, preferences: replacement.payload.preferences), replacement.payload.canonicalized)
        XCTAssertEqual(try payload(at: directory.appending(path: "WordNote.store")), original)
        let vault = WordNoteBackupVault(directoryURL: directory.appending(path: "Backups"))
        let backup = try await vault.readSnapshot(id: protection.id)
        XCTAssertEqual(backup.payload, original)
        let relaunched = try store.open()
        XCTAssertEqual(relaunched.generation, generation)
        XCTAssertEqual(relaunched.restoreOutcome, .none)
    }

    func testSnapshotEntityOrderingDoesNotChangeRestoredData() async throws {
        let original = try originalPayload()
        var reordered = try replacementSnapshot().payload
        reordered.terms.reverse()
        reordered.courses.reverse()
        let snapshot = try WordNoteSnapshotCodec.decode(WordNoteSnapshotCodec.encode(reordered, kind: .manual))
        _ = try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: await protectedBackup(original))
        let restored = try store.open()
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: restored.container.mainContext, preferences: reordered.preferences), reordered.canonicalized)
    }

    func testIncompleteAnalysesAndPreferencesRequireExplicitAcknowledgmentAcrossRestarts() async throws {
        let original = try originalPayload()
        _ = try await store.prepareRestore(replacementSnapshot(), replacing: .legacy, protectedBy: await protectedBackup(original))
        let restored = try store.open()
        XCTAssertTrue(restored.analysisRequiresResume)
        let restart = try store.open()
        XCTAssertTrue(restart.analysisRequiresResume)
        XCTAssertNotNil(restart.preferencesToApply)
        XCTAssertThrowsError(try store.authorizeAnalysisResume(for: .legacy))
        XCTAssertThrowsError(try store.acknowledgePreferences(for: .legacy))
        try store.authorizeAnalysisResume(for: restored.generation)
        try store.acknowledgePreferences(for: restored.generation)
        let acknowledged = try store.open()
        XCTAssertFalse(acknowledged.analysisRequiresResume)
        XCTAssertNil(acknowledged.preferencesToApply)
    }

    func testReadOnlyPreviewAndCancellationDoNotChangeActiveStore() async throws {
        let original = try originalPayload()
        let snapshot = try replacementSnapshot()
        let originalSession = try store.open()
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: originalSession.container.mainContext), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        _ = try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: await protectedBackup(original))
        try store.cancelPreparedRestore(replacing: .legacy)
        let reopened = try store.open()
        XCTAssertEqual(reopened.generation, .legacy)
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: reopened.container.mainContext), original)
    }

    func testRequiresProtectedBackupAndRejectsSecondPendingRestore() async throws {
        let original = try originalPayload()
        let vault = WordNoteBackupVault(directoryURL: directory.appending(path: "Backups"))
        let manual = try await vault.create(original, kind: .manual)
        let snapshot = try replacementSnapshot()
        await assertThrowsAsync({ try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: manual.snapshot) }) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .protectionRequired)
        }
        let protection = try await protectedBackup(original)
        _ = try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: protection)
        await assertThrowsAsync({ try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: protection) }) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .restoreAlreadyPending)
        }
    }

    func testStagingAndPreparationFailuresLeaveOriginalActive() async throws {
        let original = try originalPayload()
        let snapshot = try replacementSnapshot()
        let protection = try await protectedBackup(original)
        for failure in [WordNoteRestoreStore.Checkpoint.stagingSaved, .prepareJournal] {
            let failing = WordNoteRestoreStore(directoryURL: directory) { checkpoint in
                if checkpoint == failure { throw POSIXError(.ENOSPC) }
            }
            await assertThrowsAsync { try await failing.prepareRestore(snapshot, replacing: .legacy, protectedBy: protection) }
            let reopened = try store.open()
            XCTAssertEqual(reopened.generation, .legacy)
            XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: reopened.container.mainContext), original)
        }
    }

    func testActivationAndCommitFailuresRollBackToOriginal() async throws {
        let original = try originalPayload()
        let snapshot = try replacementSnapshot()
        let protection = try await protectedBackup(original)
        for failure in [WordNoteRestoreStore.Checkpoint.activateJournal, .commitJournal] {
            _ = try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: protection)
            let failing = WordNoteRestoreStore(directoryURL: directory) { checkpoint in
                if checkpoint == failure { throw POSIXError(.ENOSPC) }
            }
            let recovered = try failing.open()
            XCTAssertEqual(recovered.restoreOutcome, .rolledBack)
            XCTAssertEqual(recovered.generation, .legacy)
            XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: recovered.container.mainContext), original)
            XCTAssertEqual(try store.open().generation, .legacy)
        }
    }

    func testCrashDuringActivationReturnsToOldGenerationOnNextLaunch() async throws {
        let original = try originalPayload()
        _ = try await store.prepareRestore(replacementSnapshot(), replacing: .legacy, protectedBy: await protectedBackup(original))
        var journal = try journalObject()
        var pending = try XCTUnwrap(journal["pending"] as? [String: Any])
        pending["phase"] = "activating"
        journal["pending"] = pending
        try PrivateFileIO.write(JSONSerialization.data(withJSONObject: journal), to: journalURL)
        let recovered = try store.open()
        XCTAssertEqual(recovered.restoreOutcome, .rolledBack)
        XCTAssertEqual(recovered.generation, .legacy)
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: recovered.container.mainContext), original)
    }

    func testCorruptedStagedDataFailsChecksumAndKeepsOldStore() async throws {
        let original = try originalPayload()
        let generation = try await store.prepareRestore(replacementSnapshot(), replacing: .legacy, protectedBy: await protectedBackup(original))
        let url = generationURL(try XCTUnwrap(generation.id))
        try autoreleasepool {
            let container = try container(at: url)
            let terms = try container.mainContext.fetch(FetchDescriptor<TermModel>())
            terms[0].chineseMeaning = "Changed after staging verification."
            try container.mainContext.save()
        }
        let recovered = try store.open()
        XCTAssertEqual(recovered.restoreOutcome, .rolledBack)
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: recovered.container.mainContext), original)
    }

    func testMissingStagedStoreNeverCreatesAnEmptyReplacement() async throws {
        let original = try originalPayload()
        let generation = try await store.prepareRestore(replacementSnapshot(), replacing: .legacy, protectedBy: await protectedBackup(original))
        let url = generationURL(try XCTUnwrap(generation.id))
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        let recovered = try store.open()
        XCTAssertEqual(recovered.restoreOutcome, .rolledBack)
        XCTAssertEqual(recovered.generation, .legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSecondRestoreRetainsPreviousGenerationAndRejectsStaleTokens() async throws {
        let original = try originalPayload()
        let firstSnapshot = try replacementSnapshot()
        let firstGeneration = try await store.prepareRestore(firstSnapshot, replacing: .legacy, protectedBy: await protectedBackup(original))
        let first = try store.open()
        let firstPayload = try WordNoteSnapshotPayload.capture(from: first.container.mainContext, preferences: firstSnapshot.payload.preferences)
        let protection = try await protectedBackup(firstPayload)
        await assertThrowsAsync({ try await store.prepareRestore(firstSnapshot, replacing: .legacy, protectedBy: protection) }) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .staleGeneration)
        }
        let secondGeneration = try await store.prepareRestore(firstSnapshot, replacing: firstGeneration, protectedBy: protection)
        XCTAssertNotEqual(secondGeneration, firstGeneration)
        XCTAssertEqual(try store.open().generation, secondGeneration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.storeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "WordNote.store").path))
    }

    func testMalformedOrPathLikeGenerationFailsClosed() throws {
        let original = try originalPayload()
        try PrivateFileIO.write(Data("{\"version\":1,\"active\":{\"id\":\"../../external\"}}".utf8), to: journalURL)
        XCTAssertThrowsError(try store.open()) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .invalidJournal)
        }
        XCTAssertEqual(try payload(at: directory.appending(path: "WordNote.store")), original)
    }

    func testSymlinkedStagingDirectoryDoesNotOpenExternalStore() async throws {
        let original = try originalPayload()
        let generation = try await store.prepareRestore(replacementSnapshot(), replacing: .legacy, protectedBy: await protectedBackup(original))
        let stagedDirectory = generationURL(try XCTUnwrap(generation.id)).deletingLastPathComponent()
        try FileManager.default.removeItem(at: stagedDirectory)
        try FileManager.default.createSymbolicLink(at: stagedDirectory, withDestinationURL: directory)
        let recovered = try store.open()
        XCTAssertEqual(recovered.restoreOutcome, .rolledBack)
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: recovered.container.mainContext), original)
    }

    func testBackgroundStagingAllowsMainActorWorkAndCancellationLeavesNoPendingRestore() async throws {
        let original = try originalPayload()
        let snapshot = try replacementSnapshot()
        let protection = try await protectedBackup(original)
        let checkpoint = BlockingRestoreCheckpoint()
        let backgroundStore = WordNoteRestoreStore(directoryURL: directory) { step in
            if step == .stagingSaved { try checkpoint.waitForRelease() }
        }
        let task = Task { try await backgroundStore.prepareRestore(snapshot, replacing: .legacy, protectedBy: protection) }
        await waitForCheckpoint(checkpoint)
        XCTAssertFalse(checkpoint.wasOnMainThread)
        task.cancel()
        checkpoint.release()
        await assertThrowsAsync({ try await task.value }) { XCTAssertTrue($0 is CancellationError) }

        XCTAssertFalse(try store.hasPreparedRestore(for: .legacy))
        let reopened = try store.open()
        XCTAssertEqual(reopened.generation, .legacy)
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: reopened.container.mainContext), original)
    }

    func testPreparationReloadsJournalAfterBackgroundWork() async throws {
        let original = try originalPayload()
        let snapshot = try replacementSnapshot()
        let protection = try await protectedBackup(original)
        let checkpoint = BlockingRestoreCheckpoint()
        let backgroundStore = WordNoteRestoreStore(directoryURL: directory) { step in
            if step == .stagingSaved { try checkpoint.waitForRelease() }
        }
        let task = Task { try await backgroundStore.prepareRestore(snapshot, replacing: .legacy, protectedBy: protection) }
        await waitForCheckpoint(checkpoint)
        try store.requireAnalysisPause(for: .legacy)
        checkpoint.release()
        _ = try await task.value
        try store.cancelPreparedRestore(replacing: .legacy)

        XCTAssertTrue(try store.open().analysisRequiresResume)
    }

    func testCompetingPreparedRestoreIsNotOverwrittenAfterBackgroundWork() async throws {
        let original = try originalPayload()
        let snapshot = try replacementSnapshot()
        let protection = try await protectedBackup(original)
        let checkpoint = BlockingRestoreCheckpoint()
        let backgroundStore = WordNoteRestoreStore(directoryURL: directory) { step in
            if step == .stagingSaved { try checkpoint.waitForRelease() }
        }
        let first = Task { try await backgroundStore.prepareRestore(snapshot, replacing: .legacy, protectedBy: protection) }
        await waitForCheckpoint(checkpoint)
        let winner = try await store.prepareRestore(snapshot, replacing: .legacy, protectedBy: protection)
        checkpoint.release()
        await assertThrowsAsync({ try await first.value }) {
            XCTAssertEqual($0 as? WordNoteRestoreError, .restoreAlreadyPending)
        }

        XCTAssertEqual(try store.open().generation, winner)
    }

    private var store: WordNoteRestoreStore { WordNoteRestoreStore(directoryURL: directory) }
    private var journalURL: URL { directory.appending(path: "store-generations.json") }

    private func waitForCheckpoint(_ checkpoint: BlockingRestoreCheckpoint) async {
        for _ in 0..<1_000 {
            if checkpoint.isWaiting { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        checkpoint.release()
        XCTFail("Background staging did not reach its checkpoint.")
    }

    private func assertThrowsAsync<T>(
        _ operation: () async throws -> T, verify: (Error) -> Void = { _ in },
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected operation to fail.", file: file, line: line)
        } catch { verify(error) }
    }

    private func originalPayload() throws -> WordNoteSnapshotPayload {
        try autoreleasepool {
            let session = try store.open()
            try WordNoteTestFixture.populated.populate(session.container.mainContext)
            return try WordNoteSnapshotPayload.capture(from: session.container.mainContext)
        }
    }

    private func replacementSnapshot() throws -> DecodedWordNoteSnapshot {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        try WordNoteTestFixture.populated.populate(container.mainContext)
        var payload = try WordNoteSnapshotPayload.capture(from: container.mainContext)
        payload.terms[0].chineseMeaning = "Restored fixture definition."
        payload.preferences = .init(appearance: "dark", defaultSource: "book")
        payload.inputRecords[0].statusRaw = "analyzing"
        return try WordNoteSnapshotCodec.decode(WordNoteSnapshotCodec.encode(payload, kind: .manual))
    }

    private func protectedBackup(_ payload: WordNoteSnapshotPayload) async throws -> WordNoteBackupSummary {
        try await WordNoteBackupVault(directoryURL: directory.appending(path: "Backups"))
            .create(payload, kind: .beforeRestore).snapshot
    }

    private func container(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration("WordNote", schema: schema, url: url)])
    }

    private func payload(at url: URL) throws -> WordNoteSnapshotPayload {
        try autoreleasepool {
            let persistentContainer = try container(at: url)
            return try withExtendedLifetime(persistentContainer) {
                try WordNoteSnapshotPayload.capture(from: persistentContainer.mainContext)
            }
        }
    }

    private func generationURL(_ id: UUID) -> URL {
        directory.appending(path: "Stores/\(id.uuidString.lowercased())/WordNote.store")
    }

    private func journalObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
    }
}

private final class BlockingRestoreCheckpoint: @unchecked Sendable {
    private let condition = NSCondition()
    private var waiting = false
    private var released = false
    private var mainThread = false

    var isWaiting: Bool { condition.withLock { waiting } }
    var wasOnMainThread: Bool { condition.withLock { mainThread } }

    func waitForRelease() throws {
        condition.lock()
        defer { condition.unlock() }
        waiting = true
        mainThread = Thread.isMainThread
        let deadline = Date().addingTimeInterval(5)
        while !released {
            guard condition.wait(until: deadline) else { throw POSIXError(.ETIMEDOUT) }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
