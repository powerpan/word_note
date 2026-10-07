import Foundation
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteRepairEvidenceVaultTests: XCTestCase {
    private var directory: URL!
    private let generation = WordNoteStoreGeneration(id: UUID())

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "repair-evidence-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    func testInvalidReferencesRoundTripButCannotBeImportedAsNormalBackup() async throws {
        let source = try makeSource()
        XCTAssertThrowsError(try source.validate())
        let vault = WordNoteRepairEvidenceVault(directoryURL: directory)
        let saved = try await vault.create(source, generation: generation)
        let read = try await vault.read(id: saved.summary.id)
        XCTAssertEqual(read.payload, source)
        XCTAssertEqual(read.summary.generation, generation)
        XCTAssertEqual(read.summary.counts, source.counts)
        let url = await vault.fileURL(saved.summary.id)
        XCTAssertThrowsError(try WordNoteSnapshotReader.decode(Data(contentsOf: url)))
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(url), 0o600)
        let second = try await vault.create(source, generation: generation)
        XCTAssertNotEqual(second.summary.id, saved.summary.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testMalformedEvidenceCannotBeVerified() async throws {
        let vault = WordNoteRepairEvidenceVault(directoryURL: directory)
        let saved = try await vault.create(makeSource(), generation: generation)
        let url = await vault.fileURL(saved.summary.id)
        let bytes = try Data(contentsOf: url)
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["purpose"] = "wordnote-backup" },
            { $0["evidenceFormatVersion"] = 2 },
            { $0["schemaVersion"] = "3.0.0" },
            { $0["id"] = UUID().uuidString },
            { $0["generation"] = [:] },
            { $0["payloadChecksum"] = String(repeating: "0", count: 64) },
            { $0["payload"] = "{}" },
            { var counts = $0["counts"] as! [String: Any]; counts["terms"] = -1; $0["counts"] = counts }
        ]
        for change in changes {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            change(&object)
            try PrivateFileIO.write(JSONSerialization.data(withJSONObject: object), to: url)
            do { _ = try await vault.read(id: saved.summary.id); XCTFail("Expected invalid evidence to be rejected.") }
            catch { XCTAssertNotNil(error as? WordNoteSnapshotError) }
        }
        try PrivateFileIO.write(bytes, to: url)
        let recovered = try await vault.read(id: saved.summary.id)
        XCTAssertEqual(recovered.payload, saved.payload)
    }

    func testWriteFailuresPreservePriorEvidenceAndWrittenEvidenceRemainsReadable() async throws {
        let source = try makeSource()
        let vault = WordNoteRepairEvidenceVault(directoryURL: directory)
        let first = try await vault.create(source, generation: generation)
        for failure in [WordNoteRepairEvidenceVault.Checkpoint.beforeWrite, .afterWrite] {
            let failing = WordNoteRepairEvidenceVault(directoryURL: directory) { checkpoint in
                if checkpoint == failure { throw POSIXError(.ENOSPC) }
            }
            do { _ = try await failing.create(source, generation: generation); XCTFail("Expected write failure.") }
            catch { XCTAssertEqual(error as? POSIXError, POSIXError(.ENOSPC)) }
            let retained = try await vault.read(id: first.summary.id)
            XCTAssertEqual(retained.payload, source)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        for url in files {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let id = try XCTUnwrap(UUID(uuidString: XCTUnwrap(object["id"] as? String)))
            let read = try await vault.read(id: id)
            XCTAssertEqual(read.payload, source)
        }
    }

    func testCreateRereadsAndRejectsReplacedMetadata() async throws {
        let folder = directory!
        let vault = WordNoteRepairEvidenceVault(directoryURL: folder) { checkpoint in
            guard checkpoint == .afterWrite else { return }
            let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            object["generation"] = ["id": UUID().uuidString]
            try PrivateFileIO.write(JSONSerialization.data(withJSONObject: object), to: url)
        }
        do { _ = try await vault.create(makeSource(), generation: generation); XCTFail("Expected replaced evidence rejection.") }
        catch { XCTAssertEqual(error as? WordNoteStartupMigrationError, .protectionMismatch) }
    }

    func testSymlinkedEvidenceFileAndDirectoryAreRejected() async throws {
        let source = try makeSource()
        let vault = WordNoteRepairEvidenceVault(directoryURL: directory)
        let saved = try await vault.create(source, generation: generation)
        let url = await vault.fileURL(saved.summary.id)
        let retained = directory.appending(path: "retained.json")
        try FileManager.default.moveItem(at: url, to: retained)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: retained)
        do { _ = try await vault.read(id: saved.summary.id); XCTFail("Expected symlink rejection.") } catch {}
        let alias = directory.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let linked = WordNoteRepairEvidenceVault(directoryURL: alias)
        do { _ = try await linked.create(source, generation: generation); XCTFail("Expected directory symlink rejection.") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 3)
    }

    func testInvalidGenerationAndClockDoNotCreateEvidence() async throws {
        let source = try makeSource()
        let vault = WordNoteRepairEvidenceVault(directoryURL: directory)
        for (token, date) in [(WordNoteStoreGeneration.legacy, Date()), (generation, Date(timeIntervalSince1970: .infinity))] {
            do { _ = try await vault.create(source, generation: token, at: date); XCTFail("Expected invalid value rejection.") }
            catch { XCTAssertEqual(error as? WordNoteSnapshotError, .invalidValue) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func makeSource() throws -> WordNoteSnapshotV2Payload {
        let container = try WordNoteV2ServiceTestSupport.container()
        var source = try WordNoteV2ServiceTestSupport.snapshot(container)
        source.content.terms[0].sourceRecordID = UUID()
        return source
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }
}
