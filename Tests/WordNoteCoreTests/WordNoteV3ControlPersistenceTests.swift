import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3ControlPersistenceTests: XCTestCase {
    private typealias Support = V3SessionTestSupport

    func testFormatThreeRetainsControlsOrderAndStatisticsAcrossPopulateAndReopen() async throws {
        let payload = try controlledPayload()
        let data = try WordNoteSnapshotV3Codec.encode(payload, kind: .manual)
        let decoded = try WordNoteSnapshotV3Codec.decode(data)
        XCTAssertEqual(decoded.document.formatVersion, 3)
        XCTAssertEqual(decoded.payload, payload)
        let harness = V3RecoveryHarness(directory: try V3TestSupport.directory())
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        _ = try await harness.seed(.v3(decoded.payload))
        let reopened = try harness.store.open()
        XCTAssertEqual(try harness.capture(reopened), .v3(payload))
        let service = try WordNoteV3ReviewService(container: reopened.container)
        let stats = try service.statistics(studyTimeZoneID: Support.zone, at: Support.now)
        XCTAssertEqual(stats, try ReviewStatisticsBuilder(payload: payload).overview(studyTimeZoneID: Support.zone, at: Support.now))
    }

    func testFormatOneAndTwoRemainReadableOnlyWithoutTheirUnsupportedFields() throws {
        let original = try controlledPayload()
        for version in 1...3 {
            var payload = original
            if version < 3 {
                for index in payload.sessions.indices { payload.sessions[index].controls = nil }
                for index in payload.eventStates.indices { payload.eventStates[index].recordedOrder = nil }
            }
            if version < 2 {
                for index in payload.sessions.indices { payload.sessions[index].introductions = nil }
            }
            var document = try JSONDecoder().decode(WordNoteSnapshotV3Document.self,
                from: WordNoteSnapshotV3Codec.encode(payload, kind: .manual))
            document.formatVersion = version
            let data = try JSONEncoder().encode(document)
            XCTAssertEqual(try WordNoteSnapshotV3Codec.decode(data).payload, payload.canonicalized)
            guard case .v3(let decoded) = try WordNoteSnapshotReader.decode(data) else { return XCTFail("Expected V3") }
            XCTAssertEqual(decoded.payload, payload.canonicalized)
        }
    }

    func testControlsAndAnswerOrderIndependentlyPreventDownlabeling() throws {
        for controlsOnly in [true, false] {
            var payload = try controlledPayload()
            if controlsOnly {
                for index in payload.eventStates.indices { payload.eventStates[index].recordedOrder = nil }
            } else {
                for index in payload.sessions.indices { payload.sessions[index].controls = nil }
            }
            var document = try JSONDecoder().decode(WordNoteSnapshotV3Document.self,
                from: WordNoteSnapshotV3Codec.encode(payload, kind: .manual))
            for version in [1, 2] {
                document.formatVersion = version
                let data = try JSONEncoder().encode(document)
                XCTAssertThrowsError(try WordNoteSnapshotV3Codec.decode(data)) {
                    XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedFormat)
                }
                XCTAssertThrowsError(try WordNoteSnapshotReader.decode(data))
            }
        }
    }

    func testInvalidControlReceiptsAndMixedActionIDsFailSharedValidation() throws {
        let original = try controlledPayload()
        let changes: [(inout WordNoteSnapshotV3Payload) -> Void] = [
            { $0.sessions[0].controls?.records[0].actionID = $0.eventStates[0].actionID! },
            { value in let first = value.sessions[0].controls!.records[0]; value.sessions[0].controls?.records.append(first) },
            { $0.sessions[0].controls?.records[0].itemID = UUID() },
            { $0.sessions[0].controls?.records[0].originalCardID = UUID() },
            { $0.sessions[0].controls?.records[0].sourceFingerprint = "not-a-hash" },
            { $0.sessions[0].controls?.records[0].resultingRevision = 0 },
            { $0.sessions[0].controls?.records[0].resultingRevision = 1000 },
            { $0.sessions[0].controls?.records[0].resultingStatus = .completed },
            { $0.sessions[0].controls?.records[0].effectiveAt = Support.now.addingTimeInterval(-1) },
            { $0.sessions[0].controls?.records[0].postponedUntil = Support.now.addingTimeInterval(100) },
            { $0.sessions[0].controls?.skippedItemIDs = [UUID()] },
            { value in let id = value.sessions[0].controls!.records[0].itemID; value.sessions[0].controls?.skippedItemIDs = [id, id] },
            { $0.sessions[0].controls?.records[1].postponedUntil = Support.now },
            { $0.sessions[0].controls?.records[1].resultingStatus = .paused }
        ]
        for change in changes {
            var invalid = original
            change(&invalid)
            XCTAssertThrowsError(try invalid.validate())
            let container = try V3TestSupport.container()
            XCTAssertThrowsError(try invalid.populateEmptyStore(container.mainContext))
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<WordNoteSchemaV3.ReviewSessionModel>()), 0)
        }
    }

    func testOrderMustBePositiveUniqueBoundedAndOnlyOnCurrentSemantics() throws {
        let original = try controlledPayload()
        for value in [-1, 0, ReviewStateValidation.maximumCounter + 1] {
            var invalid = original
            invalid.eventStates[0].recordedOrder = value
            XCTAssertThrowsError(try invalid.validate())
        }
        var legacy = try V3TestSupport.payload()
        XCTAssertFalse(legacy.eventStates.isEmpty)
        legacy.eventStates[0].recordedOrder = 1
        XCTAssertThrowsError(try legacy.validate())
        let container = try Support.container(count: 2)
        let service = try WordNoteV3ReviewService(container: container)
        let (lease, _) = try Support.startPresented(service)
        _ = try Support.answer(service, lease: lease)
        _ = try Support.show(service, lease: lease)
        _ = try Support.answer(service, lease: lease)
        var duplicated = try Support.snapshot(container)
        duplicated.eventStates[1].recordedOrder = duplicated.eventStates[0].recordedOrder
        XCTAssertThrowsError(try duplicated.validate())
    }

    func testRepairEvidenceKeepsDamagedControlsButRejectsFalseOldVersion() async throws {
        var payload = try controlledPayload()
        payload.sessions[0].controls?.records[0].itemID = UUID()
        XCTAssertThrowsError(try payload.validate())
        let directory = try V3TestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WordNoteV3RepairEvidenceVault(directoryURL: directory)
        let saved = try await vault.create(payload, generation: .init(id: UUID()), at: Support.now)
        let read = try await vault.read(id: saved.summary.id)
        XCTAssertEqual(read.payload, payload.canonicalized)
        let url = await vault.fileURL(saved.summary.id)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for version in [1, 2] {
            document["evidenceFormatVersion"] = version
            try PrivateFileIO.write(JSONSerialization.data(withJSONObject: document), to: url)
            do { _ = try await vault.read(id: saved.summary.id); XCTFail("Downlabeling must fail") }
            catch { XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedFormat) }
        }
    }

    func testPreviousFormatTwoRepairEvidenceWithLedgerRemainsReadable() async throws {
        var payload = try controlledPayload()
        for index in payload.sessions.indices { payload.sessions[index].controls = nil }
        for index in payload.eventStates.indices { payload.eventStates[index].recordedOrder = nil }
        let directory = try V3TestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WordNoteV3RepairEvidenceVault(directoryURL: directory)
        let saved = try await vault.create(payload, generation: .init(id: UUID()), at: Support.now)
        let url = await vault.fileURL(saved.summary.id)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        document["evidenceFormatVersion"] = 2
        try PrivateFileIO.write(JSONSerialization.data(withJSONObject: document), to: url)
        let read = try await vault.read(id: saved.summary.id)
        XCTAssertEqual(read.payload, payload.canonicalized)
    }

    private func controlledPayload() throws -> WordNoteSnapshotV3Payload {
        let container = try Support.container(count: 2, newCards: true)
        let service = try WordNoteV3ReviewService(container: container)
        let (lease, source) = try Support.startPresented(service, newCards: true)
        _ = try service.skip(source, actionID: UUID(), lease: lease, at: Support.now)
        _ = try Support.show(service, lease: lease)
        _ = try Support.answer(service, lease: lease)
        let returned = try Support.show(service, lease: lease)
        _ = try service.later(returned, actionID: UUID(), lease: lease, at: Support.now)
        return try Support.snapshot(container)
    }
}
