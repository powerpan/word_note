import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteBackupVaultTests: XCTestCase {
    private var directory: URL!
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "backup-vault-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFirstDataThenChangedDataAfterTwentyFourHours() async throws {
        let vault = WordNoteBackupVault(directoryURL: directory)
        var payload = try fixture()
        let first = try await vault.createIfDue(payload, now: start)
        XCTAssertNotNil(first)
        let unchanged = try await vault.createIfDue(payload, now: start.addingTimeInterval(172_800))
        XCTAssertNil(unchanged)
        payload.terms[0].chineseMeaning = "changed"
        let early = try await vault.createIfDue(payload, now: start.addingTimeInterval(86_399))
        XCTAssertNil(early)
        let due = try await vault.createIfDue(payload, now: start.addingTimeInterval(86_400))
        XCTAssertNotNil(due)
        let reopened = WordNoteBackupVault(directoryURL: directory)
        let restarted = try await reopened.createIfDue(payload, now: start.addingTimeInterval(200_000))
        XCTAssertNil(restarted)
    }

    func testEmptyFirstStoreSkippedButDeletionToEmptyIsBackedUp() async throws {
        let vault = WordNoteBackupVault(directoryURL: directory)
        let empty = try fixture(.empty)
        let skipped = try await vault.createIfDue(empty, now: start)
        XCTAssertNil(skipped)
        _ = try await vault.createIfDue(fixture(), now: start)
        let afterDeletion = try await vault.createIfDue(empty, now: start.addingTimeInterval(86_400))
        XCTAssertEqual(afterDeletion?.snapshot.counts.total, 0)
    }

    func testClockRollbackDoesNotStarveOrFloodAutomaticBackups() async throws {
        let vault = WordNoteBackupVault(directoryURL: directory)
        var payload = try fixture()
        _ = try await vault.createIfDue(payload, now: start)
        payload.terms[0].chineseMeaning = "first change"
        let backwards = start.addingTimeInterval(-86_400)
        let result = try await vault.createIfDue(payload, now: backwards)
        XCTAssertNotNil(result)
        payload.terms[0].chineseMeaning = "second change"
        let tooSoon = try await vault.createIfDue(payload, now: backwards.addingTimeInterval(10))
        XCTAssertNil(tooSoon)
        let inventory = try await vault.inventory()
        XCTAssertEqual(inventory.snapshots.first?.createdAt, backwards)
    }

    func testKeepsSevenAutomaticBackupsAndAllProtectedKinds() async throws {
        let vault = WordNoteBackupVault(directoryURL: directory)
        let payload = try fixture()
        var protectedIDs = Set<UUID>()
        for kind in [WordNoteBackupKind.manual, .beforeMigration, .beforeRestore] {
            let result = try await vault.create(payload, kind: kind, now: start)
            protectedIDs.insert(result.snapshot.id)
        }
        var automaticIDs: [UUID] = []
        for offset in 0..<10 {
            let result = try await vault.create(payload, kind: .automatic, now: start.addingTimeInterval(Double(offset)))
            automaticIDs.append(result.snapshot.id)
            XCTAssertFalse(result.retentionNeedsAttention)
        }
        let inventory = try await vault.inventory()
        XCTAssertEqual(inventory.snapshots.count, 10)
        XCTAssertEqual(Set(inventory.snapshots.filter { $0.kind != .automatic }.map(\.id)), protectedIDs)
        XCTAssertEqual(Set(inventory.snapshots.filter { $0.kind == .automatic }.map(\.id)), Set(automaticIDs.suffix(7)))
    }

    func testSnapshotWriteFailureNeverDeletesPreviousBackups() async throws {
        let vault = WordNoteBackupVault(directoryURL: directory)
        let payload = try fixture()
        for _ in 0..<7 { _ = try await vault.create(payload, kind: .automatic) }
        let before = try await vault.inventory()
        let failing = WordNoteBackupVault(directoryURL: directory) { checkpoint in
            if checkpoint == .snapshotWrite { throw POSIXError(.ENOSPC) }
        }
        do {
            _ = try await failing.create(payload, kind: .automatic)
            XCTFail("Expected a simulated full disk.")
        } catch { XCTAssertEqual(error as? POSIXError, POSIXError(.ENOSPC)) }
        let after = try await vault.inventory()
        XCTAssertEqual(after.snapshots, before.snapshots)
    }

    func testCatalogFailureLeavesRecoverableNewBackupAndDoesNotPrune() async throws {
        let vault = WordNoteBackupVault(directoryURL: directory)
        let payload = try fixture()
        for _ in 0..<7 { _ = try await vault.create(payload, kind: .automatic) }
        let before = try await vault.inventory()
        let failing = WordNoteBackupVault(directoryURL: directory) { checkpoint in
            if checkpoint == .catalogWrite { throw POSIXError(.ENOSPC) }
        }
        do {
            _ = try await failing.create(payload, kind: .automatic)
            XCTFail("Expected a simulated catalog failure.")
        } catch { XCTAssertEqual(error as? POSIXError, POSIXError(.ENOSPC)) }
        let recovered = try await vault.inventory()
        XCTAssertEqual(recovered.snapshots.count, 8)
        XCTAssertTrue(Set(before.snapshots.map(\.id)).isSubset(of: Set(recovered.snapshots.map(\.id))))
        _ = try await vault.create(payload, kind: .automatic)
        let cleaned = try await vault.inventory()
        XCTAssertEqual(cleaned.snapshots.count, 7)
    }

    func testPruningFailureIsReportedWithoutLosingNewSnapshot() async throws {
        let vault = WordNoteBackupVault(directoryURL: directory)
        let payload = try fixture()
        for _ in 0..<7 { _ = try await vault.create(payload, kind: .automatic) }
        let failing = WordNoteBackupVault(directoryURL: directory) { checkpoint in
            if checkpoint == .pruning { throw POSIXError(.EACCES) }
        }
        let result = try await failing.create(payload, kind: .automatic)
        XCTAssertTrue(result.retentionNeedsAttention)
        let restored = try await vault.readSnapshot(id: result.snapshot.id)
        XCTAssertEqual(restored.payload, payload)
        let inventory = try await vault.inventory()
        XCTAssertEqual(inventory.snapshots.count, 8)
        let retry = try await vault.createIfDue(payload)
        XCTAssertNil(retry)
        let cleaned = try await vault.inventory()
        XCTAssertEqual(cleaned.snapshots.count, 7)
        XCTAssertTrue(cleaned.snapshots.contains { $0.id == result.snapshot.id })
    }

    func testCorruptFilesAndSpoofedIDsAreNotListedOrPruned() async throws {
        let vault = WordNoteBackupVault(directoryURL: directory)
        let payload = try fixture()
        _ = try await vault.create(payload, kind: .manual)
        let corrupt = directory.appending(path: UUID().uuidString.lowercased() + ".wordnote-backup.json")
        try PrivateFileIO.write(Data("broken".utf8), to: corrupt)
        let spoofed = directory.appending(path: UUID().uuidString.lowercased() + ".wordnote-backup.json")
        try PrivateFileIO.write(WordNoteSnapshotCodec.encode(payload, kind: .automatic), to: spoofed)
        for _ in 0..<8 { _ = try await vault.create(payload, kind: .automatic) }
        let inventory = try await vault.inventory()
        XCTAssertEqual(inventory.unreadableFileCount, 2)
        XCTAssertEqual(inventory.snapshots.count, 8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: spoofed.path))
    }

    func testCorruptCatalogCanBeRebuiltWithoutDroppingValidSnapshots() async throws {
        let vault = WordNoteBackupVault(directoryURL: directory)
        let payload = try fixture()
        let first = try await vault.create(payload, kind: .manual, now: start)
        try PrivateFileIO.write(Data("broken".utf8), to: directory.appending(path: "catalog.json"))
        let inventory = try await vault.inventory()
        XCTAssertTrue(inventory.recoveredCatalog)
        XCTAssertEqual(inventory.snapshots.map(\.id), [first.snapshot.id])
        _ = try await vault.create(payload, kind: .manual, now: start.addingTimeInterval(1))
        let repaired = try await vault.inventory()
        XCTAssertFalse(repaired.recoveredCatalog)
        XCTAssertEqual(repaired.snapshots.count, 2)
    }

    func testExportImportPermissionsAndExplicitDelete() async throws {
        let vault = WordNoteBackupVault(directoryURL: directory)
        let payload = try fixture()
        let result = try await vault.create(payload, kind: .manual)
        let export = directory.appending(path: "user-export.json")
        try await vault.exportSnapshot(payload, to: export)
        let decoded = try await vault.readSnapshot(at: export)
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: export.path)[.posixPermissions] as? Int, 0o600)
        let csv = directory.appending(path: "selected.csv")
        try await vault.exportCSV(terms: [payload.terms[0]], courses: payload.courses, to: csv)
        XCTAssertEqual(try Data(contentsOf: csv), VocabularyCSVExporter.export(terms: [payload.terms[0]], courses: payload.courses))
        try await vault.delete(id: result.snapshot.id)
        let remaining = try await vault.inventory()
        XCTAssertTrue(remaining.snapshots.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))
    }

    private func fixture(_ fixture: WordNoteTestFixture = .populated) throws -> WordNoteSnapshotPayload {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        try fixture.populate(container.mainContext)
        return try WordNoteSnapshotPayload.capture(from: container.mainContext)
    }
}
