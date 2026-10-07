import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteVersionedBackupVaultTests: XCTestCase {
    private var root: URL!
    private typealias Support = WordNoteV2ServiceTestSupport

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "versioned-vault-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMixedInventoryHasExplicitSchemasAndCompleteEightEntityCounts() async throws {
        let vault = WordNoteBackupVault(directoryURL: root, appVersion: "test-version")
        let v1 = try v1Payload()
        let v2 = try v2Payload()
        let first = try await vault.create(v1, kind: .beforeMigration, now: Support.now)
        let second = try await vault.create(v2, kind: .manual, now: Support.now.addingTimeInterval(1))
        let reopened = WordNoteBackupVault(directoryURL: root)
        let inventory = try await reopened.inventory()
        XCTAssertEqual(inventory.snapshots.map(\.id), [second.snapshot.id, first.snapshot.id])
        XCTAssertEqual(inventory.snapshots.map(\.schemaVersion), [.v2, .v1])
        XCTAssertEqual(first.snapshot.counts, WordNoteBackupCounts(v1.counts))
        XCTAssertEqual(second.snapshot.counts, WordNoteBackupCounts(v2.counts))
        XCTAssertEqual(second.snapshot.counts.total, v2.counts.total)
        XCTAssertGreaterThan(second.snapshot.counts.total, v2.content.counts.total)
        XCTAssertEqual(first.snapshot.counts.occurrences, 0)
        XCTAssertEqual(second.snapshot.appVersion, "test-version")
        XCTAssertEqual(inventory.unreadableFileCount, 0)
    }

    func testV2RoundTripKeepsAllMetadataAndLegacyReadersRejectInsteadOfFlattening() async throws {
        let vault = WordNoteBackupVault(directoryURL: root)
        let payload = try v2Payload()
        let result = try await vault.create(payload, kind: .manual, now: Support.now)
        let decoded = try await vault.readVersionedSnapshot(id: result.snapshot.id)
        XCTAssertEqual(decoded.payload, .v2(payload))
        XCTAssertEqual(decoded.summary, result.snapshot)
        XCTAssertEqual(try decoded.payload.contentChecksum(), result.snapshot.payloadChecksum)
        for useID in [false, true] {
            do {
                if useID { _ = try await vault.readSnapshot(id: result.snapshot.id) }
                else { _ = try await vault.readSnapshot(at: file(result.snapshot.id)) }
                XCTFail("The V1 API must not discard V2 relationships.")
            } catch { XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedSchema) }
        }
        let old = try await vault.create(v1Payload(), kind: .manual, now: Support.now)
        let legacy = try await vault.readSnapshot(id: old.snapshot.id)
        XCTAssertEqual(legacy.payload, try v1Payload())
    }

    func testV2ExportByIDPreservesBytesAndNewExportKeepsFullPayloadAndPermissions() async throws {
        let vault = WordNoteBackupVault(directoryURL: root)
        let payload = try v2Payload()
        let result = try await vault.create(payload, kind: .beforeRestore, now: Support.now)
        let copied = root.appending(path: "copied.json")
        try await vault.exportSnapshot(id: result.snapshot.id, to: copied)
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: file(result.snapshot.id)))
        let exported = root.appending(path: "current.json")
        try await vault.exportSnapshot(WordNoteVersionedPayload.v2(payload), to: exported)
        let decoded = try await vault.readVersionedSnapshot(at: exported)
        XCTAssertEqual(decoded.payload, .v2(payload))
        XCTAssertEqual(decoded.summary.kind, .manual)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: exported.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int, 0o700)
        try await vault.delete(id: result.snapshot.id)
        let inventory = try await vault.inventory()
        XCTAssertTrue(inventory.snapshots.isEmpty)
        XCTAssertEqual(try WordNoteSnapshotReader.decode(Data(contentsOf: copied)).payload, .v2(payload))
    }

    func testAutomaticBackupDetectsChangesOnlyInV2RelationsOrMetadata() async throws {
        let vault = WordNoteBackupVault(directoryURL: root)
        var payload = try v2Payload()
        let first = try await vault.createIfDue(payload, now: Support.now)
        XCTAssertNotNil(first)
        let unchanged = try await vault.createIfDue(payload, now: Support.now.addingTimeInterval(86_400))
        XCTAssertNil(unchanged)
        let originalContent = payload.content
        payload.occurrences[0].note = "Only a source changed"
        let early = try await vault.createIfDue(payload, now: Support.now.addingTimeInterval(10))
        XCTAssertNil(early)
        let due = try await vault.createIfDue(payload, now: Support.now.addingTimeInterval(86_400))
        XCTAssertNotNil(due)
        payload.termStates[0].revision += 1
        let metadata = try await vault.createIfDue(payload, now: Support.now.addingTimeInterval(172_800))
        XCTAssertNotNil(metadata)
        payload.courseLinks.removeLast()
        let membership = try await vault.createIfDue(payload, now: Support.now.addingTimeInterval(259_200))
        XCTAssertNotNil(membership)
        XCTAssertEqual(payload.content, originalContent)
        let restarted = WordNoteBackupVault(directoryURL: root)
        let same = try await restarted.createIfDue(payload, now: Support.now.addingTimeInterval(345_600))
        XCTAssertNil(same)
    }

    func testEmptyV2FirstBackupIsSkippedButSchemaChangeAndDeletionAreBackedUp() async throws {
        let vault = WordNoteBackupVault(directoryURL: root)
        let empty = try Support.snapshot(Support.container(populated: false))
        let skipped = try await vault.createIfDue(empty, now: Support.now)
        XCTAssertNil(skipped)
        let v1Empty = empty.content
        _ = try await vault.create(v1Empty, kind: .beforeMigration, now: Support.now)
        let upgraded = try await vault.createIfDue(empty, now: Support.now.addingTimeInterval(86_400))
        XCTAssertEqual(upgraded?.snapshot.schemaVersion, .v2)
        _ = try await vault.create(v2Payload(), kind: .manual, now: Support.now.addingTimeInterval(172_800))
        let deleted = try await vault.createIfDue(empty, now: Support.now.addingTimeInterval(259_200))
        XCTAssertEqual(deleted?.snapshot.counts.total, 0)
    }

    func testMixedRetentionKeepsSevenNewestAutomaticAndEveryProtectedSnapshot() async throws {
        let vault = WordNoteBackupVault(directoryURL: root)
        let versions: [WordNoteVersionedPayload] = [.v1(try v1Payload()), .v2(try v2Payload())]
        var protected = Set<UUID>()
        for payload in versions {
            for kind in [WordNoteBackupKind.manual, .beforeMigration, .beforeRestore] {
                protected.insert(try await vault.create(payload, kind: kind, now: Support.now).snapshot.id)
            }
        }
        var automatic: [UUID] = []
        for index in 0..<10 {
            automatic.append(try await vault.create(versions[index % 2], kind: .automatic, now: Support.now.addingTimeInterval(Double(index))).snapshot.id)
        }
        let inventory = try await vault.inventory()
        XCTAssertEqual(inventory.snapshots.count, 13)
        XCTAssertEqual(Set(inventory.snapshots.filter { $0.kind != .automatic }.map(\.id)), protected)
        XCTAssertEqual(Set(inventory.snapshots.filter { $0.kind == .automatic }.map(\.id)), Set(automatic.suffix(7)))
    }

    func testCatalogRecoveryRetainsBothSchemasAndRepairsOrdering() async throws {
        let vault = WordNoteBackupVault(directoryURL: root)
        let old = try await vault.create(v1Payload(), kind: .manual, now: Support.now)
        let new = try await vault.create(v2Payload(), kind: .manual, now: Support.now.addingTimeInterval(1))
        try PrivateFileIO.write(Data("broken".utf8), to: root.appending(path: "catalog.json"))
        let recovered = try await vault.inventory()
        XCTAssertTrue(recovered.recoveredCatalog)
        XCTAssertEqual(recovered.snapshots.map(\.id), [new.snapshot.id, old.snapshot.id])
        _ = try await vault.create(v2Payload(), kind: .manual, now: Support.now.addingTimeInterval(2))
        let repaired = try await vault.inventory()
        XCTAssertFalse(repaired.recoveredCatalog)
        XCTAssertEqual(repaired.snapshots.count, 3)
    }

    func testV2WriteAndCatalogFailuresNeverRemoveEarlierMixedBackups() async throws {
        let payload = try v2Payload()
        let vault = WordNoteBackupVault(directoryURL: root)
        _ = try await vault.create(v1Payload(), kind: .beforeMigration, now: Support.now)
        for _ in 0..<7 { _ = try await vault.create(payload, kind: .automatic, now: Support.now) }
        let before = try await vault.inventory()
        for failure in [WordNoteBackupVault.Checkpoint.snapshotWrite, .catalogWrite] {
            let failing = WordNoteBackupVault(directoryURL: root) { checkpoint in
                if checkpoint == failure { throw POSIXError(.ENOSPC) }
            }
            do { _ = try await failing.create(payload, kind: .automatic); XCTFail("Expected injected IO failure.") }
            catch { XCTAssertEqual(error as? POSIXError, POSIXError(.ENOSPC)) }
            let after = try await vault.inventory()
            XCTAssertTrue(Set(before.snapshots.map(\.id)).isSubset(of: Set(after.snapshots.map(\.id))))
        }
    }

    func testV2PruningFailureKeepsNewBackupReadableAndRetryRecovers() async throws {
        let vault = WordNoteBackupVault(directoryURL: root)
        let payload = try v2Payload()
        for _ in 0..<7 { _ = try await vault.create(payload, kind: .automatic, now: Support.now) }
        let failing = WordNoteBackupVault(directoryURL: root) { checkpoint in
            if checkpoint == .pruning { throw POSIXError(.EACCES) }
        }
        let result = try await failing.create(payload, kind: .automatic, now: Support.now)
        XCTAssertTrue(result.retentionNeedsAttention)
        let decoded = try await vault.readVersionedSnapshot(id: result.snapshot.id)
        XCTAssertEqual(decoded.payload, .v2(payload))
        try await vault.maintainAutomaticRetention()
        let inventory = try await vault.inventory()
        XCTAssertEqual(inventory.snapshots.count, 7)
        XCTAssertTrue(inventory.snapshots.contains { $0.id == result.snapshot.id })
    }

    func testUnknownSchemaCorruptionAndSpoofedIDStayUnlistedAndUnpruned() async throws {
        let vault = WordNoteBackupVault(directoryURL: root)
        let payload = try v2Payload()
        _ = try await vault.create(payload, kind: .manual, now: Support.now)
        let valid = try WordNoteSnapshotV2Codec.decode(WordNoteSnapshotV2Codec.encode(payload, kind: .automatic)).document
        var unknown = valid
        unknown.sourceSchemaVersion = "99.0.0"
        try PrivateFileIO.write(JSONEncoder().encode(unknown), to: file(unknown.snapshotID))
        var corrupt = valid
        corrupt.snapshotID = UUID()
        corrupt.counts.lookupEvents += 1
        try PrivateFileIO.write(JSONEncoder().encode(corrupt), to: file(corrupt.snapshotID))
        let spoofedID = UUID()
        try PrivateFileIO.write(JSONEncoder().encode(valid), to: file(spoofedID))
        for _ in 0..<8 { _ = try await vault.create(payload, kind: .automatic, now: Support.now) }
        let inventory = try await vault.inventory()
        XCTAssertEqual(inventory.unreadableFileCount, 3)
        XCTAssertEqual(inventory.snapshots.count, 8)
        for id in [unknown.snapshotID, corrupt.snapshotID, spoofedID] { XCTAssertTrue(FileManager.default.fileExists(atPath: file(id).path)) }
        let destination = root.appending(path: "preserved.json")
        try PrivateFileIO.write(Data("keep".utf8), to: destination)
        do { try await vault.exportSnapshot(id: spoofedID, to: destination); XCTFail("Spoofed file must not export.") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotError, .invalidDocument) }
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep".utf8))
    }

    func testInvalidV2PayloadAndClockNeverWriteOrPruneBackups() async throws {
        let vault = WordNoteBackupVault(directoryURL: root)
        let original = try v2Payload()
        _ = try await vault.create(original, kind: .manual, now: Support.now)
        let before = try await vault.inventory()
        var invalid = original
        invalid.occurrences[0].termID = UUID()
        do { _ = try await vault.create(invalid, kind: .automatic); XCTFail("Invalid relationship must not save.") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotError, .missingReference) }
        do { _ = try await vault.createIfDue(original, now: Date(timeIntervalSince1970: .nan)); XCTFail("Invalid clock must not trigger maintenance.") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotError, .invalidValue) }
        let after = try await vault.inventory()
        XCTAssertEqual(after.snapshots, before.snapshots)
    }

    private func file(_ id: UUID) -> URL {
        root.appending(path: id.uuidString.lowercased() + ".wordnote-backup.json")
    }

    private func v1Payload() throws -> WordNoteSnapshotPayload {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        try WordNoteTestFixture.populated.populate(container.mainContext)
        return try WordNoteSnapshotPayload.capture(from: container.mainContext)
    }

    private func v2Payload() throws -> WordNoteSnapshotV2Payload {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let courseID = try Support.snapshot(container).content.courses[1].id
        _ = try service.capture(.init(rawText: "quick", courseID: courseID, note: "Another encounter", capturedVia: .floatingQuickAdd), at: Support.now)
        var payload = try Support.snapshot(container)
        payload.content.preferences = .init(appearance: "dark", defaultSource: "paper")
        payload.recordStates[0].queueStateRaw = "failed"
        payload.recordStates[0].attemptID = UUID()
        payload.recordStates[0].autoRetryCount = 1
        payload.recordStates[0].nextAttemptAt = Support.now.addingTimeInterval(60)
        payload.occurrences[0].sourceTitle = "Synthetic reading source"
        payload.occurrences[0].sourceURL = "https://example.com/reading"
        payload.occurrences[0].sourcePage = "7"
        try payload.validate()
        return payload
    }
}
