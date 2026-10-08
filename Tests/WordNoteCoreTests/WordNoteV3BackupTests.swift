import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3BackupTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws { directory = try V3TestSupport.directory() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    func testVersionedBackgroundCapturePreservesElevenEntitiesAndCompleteMetadata() async throws {
        let expected = try V3TestSupport.reviewedPayload().canonicalized
        let container = try V3TestSupport.container(url: directory.appending(path: "source.store"))
        defer { withExtendedLifetime(container) {} }
        try expected.populateEmptyStore(container.mainContext)
        let payload = try await WordNoteSnapshotCapture(container: container).captureVersioned(preferences: expected.content.content.preferences)
        XCTAssertEqual(payload, .v3(expected))
        XCTAssertEqual(payload.counts, WordNoteBackupCounts(expected.counts))
        XCTAssertEqual(payload.counts.total, expected.counts.total)
        let id = UUID()
        XCTAssertEqual(try payload.encode(kind: .manual, snapshotID: id, createdAt: V3TestSupport.date),
                       try WordNoteSnapshotV3Codec.encode(expected, kind: .manual, snapshotID: id, createdAt: V3TestSupport.date))
        do { _ = try await WordNoteSnapshotCapture(container: container).capture(); XCTFail("V1 must not flatten V3.") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedSchema) }
    }

    func testPendingV3DraftIsNotSavedOrDiscarded() async throws {
        let payload = try V3TestSupport.reviewedPayload()
        let container = try V3TestSupport.container()
        defer { withExtendedLifetime(container) {} }
        try payload.populateEmptyStore(container.mainContext)
        let card = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewCardModel>()).first)
        card.revision += 1
        do { _ = try await WordNoteSnapshotCapture(container: container).captureVersioned(); XCTFail("Cannot commit a foreign draft.") }
        catch { XCTAssertEqual(error as? WordNoteV2ContentError, .unsavedChanges) }
        XCTAssertTrue(container.mainContext.hasChanges)
        container.mainContext.rollback()
        XCTAssertEqual(try WordNoteSnapshotV3Payload.capture(from: container.mainContext),
                       replacingPreferences(payload, with: .init()).canonicalized)
    }

    func testConcurrentCardSaveRetriesTheWholeSnapshot() async throws {
        let container = try V3TestSupport.container()
        defer { withExtendedLifetime(container) {} }
        try V3TestSupport.reviewedPayload().populateEmptyStore(container.mainContext)
        let probe = V3CaptureCounter()
        let reader = WordNoteSnapshotCapture(versionedContainer: container) { container, preferences in
            let attempt = await probe.increment()
            let captured = try await WordNoteSnapshotCapture.readVersionedOnBackgroundExecutor(container: container, preferences: preferences)
            if attempt == 1 {
                try await MainActor.run {
                    let context = ModelContext(container)
                    context.autosaveEnabled = false
                    let session = try XCTUnwrap(context.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewSessionModel>()).first)
                    session.revision += 1
                    try context.save()
                }
            }
            return captured
        }
        let value = try await reader.captureVersioned()
        let latest = try await WordNoteSnapshotCapture(container: container).captureVersioned()
        XCTAssertEqual(value, latest)
        let attempts = await probe.count
        XCTAssertEqual(attempts, 2)
        guard case .v3(let actual) = value else { return XCTFail("Missing V3 payload.") }
        XCTAssertEqual(actual.sessions[0].revision, 3)
    }

    func testWrongSchemaReaderResultCannotEscapeAsV3() async throws {
        let container = try V3TestSupport.container()
        defer { withExtendedLifetime(container) {} }
        let old = try V3TestSupport.source()
        let reader = WordNoteSnapshotCapture(versionedContainer: container) { _, _ in .v2(old) }
        do { _ = try await reader.captureVersioned(); XCTFail("A mislabeled reader must fail.") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedSchema) }
    }

    func testV3VaultInventoryExportAndLegacyReaderBoundaries() async throws {
        let vault = WordNoteBackupVault(directoryURL: directory, appVersion: "v3-test")
        let payload = try V3TestSupport.reviewedPayload().canonicalized
        _ = try await vault.create(payload.content.content, kind: .beforeMigration)
        _ = try await vault.create(payload.content, kind: .beforeMigration)
        let result = try await vault.create(payload, kind: .manual)
        let reopened = WordNoteBackupVault(directoryURL: directory)
        let inventory = try await reopened.inventory()
        XCTAssertEqual(inventory.snapshots.map(\.schemaVersion), [.v3, .v2, .v1])
        XCTAssertEqual(inventory.unreadableFileCount, 0)
        XCTAssertEqual(result.snapshot.counts, WordNoteBackupCounts(payload.counts))
        XCTAssertEqual(result.snapshot.appVersion, "v3-test")
        let decoded = try await reopened.readVersionedSnapshot(id: result.snapshot.id)
        XCTAssertEqual(decoded.payload, .v3(payload))
        XCTAssertEqual(decoded.summary, result.snapshot)
        let export = directory.appending(path: "copied.json")
        try await reopened.exportSnapshot(id: result.snapshot.id, to: export)
        let sourceURL = directory.appending(path: result.snapshot.id.uuidString.lowercased() + ".wordnote-backup.json")
        XCTAssertEqual(try Data(contentsOf: export), try Data(contentsOf: sourceURL))
        try await reopened.exportSnapshot(payload, to: export)
        XCTAssertEqual(try WordNoteSnapshotReader.decode(Data(contentsOf: export)).payload, .v3(payload))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: export.path)[.posixPermissions] as? Int, 0o600)
        for byID in [false, true] {
            do {
                if byID { _ = try await reopened.readSnapshot(id: result.snapshot.id) }
                else { _ = try await reopened.readSnapshot(at: sourceURL) }
                XCTFail("V1 API must not discard cards or sessions.")
            } catch { XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedSchema) }
        }
    }

    func testAutomaticBackupDetectsOnlyCardOrSessionChanges() async throws {
        let vault = WordNoteBackupVault(directoryURL: directory)
        var payload = try V3TestSupport.reviewedPayload()
        let initial = try await vault.createIfDue(payload, now: V3TestSupport.date)
        XCTAssertNotNil(initial)
        let unchanged = try await vault.createIfDue(payload, now: V3TestSupport.date.addingTimeInterval(86_400))
        XCTAssertNil(unchanged)
        let content = payload.content
        payload.cards[0].revision += 1
        let card = try await vault.createIfDue(payload, now: V3TestSupport.date.addingTimeInterval(86_400))
        XCTAssertNotNil(card)
        payload.sessions[0].revision += 1
        let session = try await vault.createIfDue(payload, now: V3TestSupport.date.addingTimeInterval(172_800))
        XCTAssertNotNil(session)
        payload.sessionItems[0].updatedAt = V3TestSupport.date.addingTimeInterval(1)
        let item = try await vault.createIfDue(payload, now: V3TestSupport.date.addingTimeInterval(259_200))
        XCTAssertNotNil(item)
        XCTAssertEqual(payload.content, content)
    }

    func testCorruptV3BackupCannotBeListedOrExportedAndIsNotPruned() async throws {
        let vault = WordNoteBackupVault(directoryURL: directory)
        let payload = try V3TestSupport.reviewedPayload()
        let saved = try await vault.create(payload, kind: .automatic)
        let url = directory.appending(path: saved.snapshot.id.uuidString.lowercased() + ".wordnote-backup.json")
        var document = try WordNoteSnapshotV3Codec.decode(Data(contentsOf: url)).document
        document.counts.sessions += 1
        try PrivateFileIO.write(JSONEncoder().encode(document), to: url)
        for _ in 0..<8 { _ = try await vault.create(payload, kind: .automatic) }
        let inventory = try await vault.inventory()
        XCTAssertEqual(inventory.snapshots.count, 7)
        XCTAssertEqual(inventory.unreadableFileCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let output = directory.appending(path: "keep.json")
        try PrivateFileIO.write(Data("keep".utf8), to: output)
        do { try await vault.exportSnapshot(id: saved.snapshot.id, to: output); XCTFail("Invalid backup must not export.") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotError, .countMismatch) }
        XCTAssertEqual(try Data(contentsOf: output), Data("keep".utf8))
    }

    func testV3ResumeSignalIncludesInterruptedAndFailedAnalysis() throws {
        let base = try V3TestSupport.payload()
        for state in ["idle", "queued", "running", "failed"] {
            var payload = base
            for index in payload.content.content.inputRecords.indices {
                payload.content.content.inputRecords[index].statusRaw = "analyzed"
            }
            XCTAssertFalse(payload.content.recordStates.isEmpty)
            for index in payload.content.recordStates.indices { payload.content.recordStates[index].queueStateRaw = state }
            XCTAssertEqual(WordNoteVersionedPayload.v3(payload).requiresAnalysisResume, state != "idle")
        }
    }

    private func replacingPreferences(_ source: WordNoteSnapshotV3Payload, with preferences: WordNoteSnapshotPayload.Preferences) -> WordNoteSnapshotV3Payload {
        var copy = source
        copy.content.content.preferences = preferences
        return copy
    }
}

private actor V3CaptureCounter {
    private(set) var count = 0
    func increment() -> Int { count += 1; return count }
}
