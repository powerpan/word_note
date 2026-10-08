import Foundation
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3RepairEvidenceTests: XCTestCase {
    private var directory: URL!
    private let generation = WordNoteStoreGeneration(id: UUID())

    override func setUp() async throws { directory = try V3TestSupport.directory().appending(path: "Evidence") }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    func testEvidenceIncludesAllElevenEntitiesEvenWhenReviewRelationshipsAreInvalid() async throws {
        var source = try V3TestSupport.reviewedPayload().canonicalized
        source.sessionItems[0].sessionID = UUID()
        source.content.content.terms[0].sourceRecordID = UUID()
        let vault = WordNoteV3RepairEvidenceVault(directoryURL: directory)
        let saved = try await vault.create(source, generation: generation, at: V3TestSupport.date)
        let read = try await vault.read(id: saved.summary.id)
        XCTAssertEqual(read.payload, source)
        XCTAssertEqual(read.summary.counts, source.counts)
        XCTAssertEqual(read.summary.generation, generation)
        XCTAssertEqual(read.summary.createdAt, V3TestSupport.date)
        let url = await vault.fileURL(saved.summary.id)
        XCTAssertThrowsError(try source.validate())
        XCTAssertThrowsError(try WordNoteSnapshotReader.decode(Data(contentsOf: url)))
        let oldReader = WordNoteRepairEvidenceVault(directoryURL: directory)
        do { _ = try await oldReader.read(id: saved.summary.id); XCTFail("V2 evidence reader must reject V3.") }
        catch { XCTAssertNotNil(error as? WordNoteSnapshotError) }
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(url), 0o600)
        let next = try await vault.create(source, generation: generation)
        XCTAssertNotEqual(next.summary.id, saved.summary.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testHeaderPayloadAndV3CountTamperingAreRejected() async throws {
        let vault = WordNoteV3RepairEvidenceVault(directoryURL: directory)
        let saved = try await vault.create(V3TestSupport.reviewedPayload(), generation: generation)
        let url = await vault.fileURL(saved.summary.id)
        let bytes = try Data(contentsOf: url)
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["purpose"] = "wordnote-backup" },
            { $0["evidenceFormatVersion"] = 5 },
            { $0["schemaVersion"] = "2.0.0" },
            { $0["id"] = UUID().uuidString },
            { $0["generation"] = [:] },
            { $0["payloadChecksum"] = String(repeating: "0", count: 64) },
            { $0["payload"] = "{}" },
            { var counts = $0["counts"] as! [String: Any]; counts["cards"] = -1; $0["counts"] = counts },
            { var counts = $0["counts"] as! [String: Any]; counts["sessions"] = 99; $0["counts"] = counts },
            { var counts = $0["counts"] as! [String: Any]; counts.removeValue(forKey: "sessionItems"); $0["counts"] = counts }
        ]
        for change in changes {
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            change(&document)
            try PrivateFileIO.write(JSONSerialization.data(withJSONObject: document), to: url)
            do { _ = try await vault.read(id: saved.summary.id); XCTFail("Tampered evidence must be rejected.") }
            catch { XCTAssertNotNil(error as? WordNoteSnapshotError) }
        }
        try PrivateFileIO.write(bytes, to: url)
        let retained = try await vault.read(id: saved.summary.id)
        XCTAssertEqual(retained.payload, saved.payload)
    }

    func testWriteFaultsNeverOverwritePriorEvidence() async throws {
        let payload = try V3TestSupport.reviewedPayload().canonicalized
        let vault = WordNoteV3RepairEvidenceVault(directoryURL: directory)
        let original = try await vault.create(payload, generation: generation)
        for step in [WordNoteV3RepairEvidenceVault.Checkpoint.beforeWrite, .afterWrite] {
            let failing = WordNoteV3RepairEvidenceVault(directoryURL: directory) { if $0 == step { throw POSIXError(.ENOSPC) } }
            do { _ = try await failing.create(payload, generation: generation); XCTFail("Expected IO fault.") }
            catch { XCTAssertEqual(error as? POSIXError, POSIXError(.ENOSPC)) }
            let retained = try await vault.read(id: original.summary.id)
            XCTAssertEqual(retained.payload, payload)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        for file in files {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let id = try XCTUnwrap(UUID(uuidString: XCTUnwrap(object["id"] as? String)))
            let read = try await vault.read(id: id)
            XCTAssertEqual(read.payload, payload)
        }
    }

    func testEvidenceCreateRereadsAndRejectsGenerationOrDateReplacement() async throws {
        for field in ["generation", "createdAt"] {
            let folder = directory.appending(path: field)
            let vault = WordNoteV3RepairEvidenceVault(directoryURL: folder) { checkpoint in
                guard checkpoint == .afterWrite else { return }
                let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                object[field] = field == "generation" ? ["id": UUID().uuidString] : 0
                try PrivateFileIO.write(JSONSerialization.data(withJSONObject: object), to: url)
            }
            do { _ = try await vault.create(V3TestSupport.reviewedPayload(), generation: generation); XCTFail("Replaced evidence must fail reread verification.") }
            catch { XCTAssertEqual(error as? WordNoteStartupMigrationError, .protectionMismatch) }
        }
    }

    func testSymlinkedEvidenceAndDirectoryCannotBeFollowed() async throws {
        let source = try V3TestSupport.reviewedPayload()
        let vault = WordNoteV3RepairEvidenceVault(directoryURL: directory)
        let saved = try await vault.create(source, generation: generation)
        let file = await vault.fileURL(saved.summary.id)
        let retained = directory.appending(path: "retained.json")
        try FileManager.default.moveItem(at: file, to: retained)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: retained)
        do { _ = try await vault.read(id: saved.summary.id); XCTFail("Expected file symlink rejection.") } catch {}
        let alias = directory.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        do {
            _ = try await WordNoteV3RepairEvidenceVault(directoryURL: alias).create(source, generation: generation)
            XCTFail("Expected directory symlink rejection.")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 3)
    }

    func testInvalidGenerationOrClockProducesNoEvidence() async throws {
        let vault = WordNoteV3RepairEvidenceVault(directoryURL: directory)
        for (token, date) in [(WordNoteStoreGeneration.legacy, Date()), (generation, Date(timeIntervalSince1970: .infinity))] {
            do { _ = try await vault.create(V3TestSupport.reviewedPayload(), generation: token, at: date); XCTFail("Expected invalid value.") }
            catch { XCTAssertEqual(error as? WordNoteSnapshotError, .invalidValue) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }
}
