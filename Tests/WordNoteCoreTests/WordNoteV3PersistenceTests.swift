import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3PersistenceTests: XCTestCase {
    func testFrozenOriginalV1StoreMigratesOfflineThroughV2IntoSeparateV3Store() throws {
        let directory = try V3TestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "v1", withExtension: "store", subdirectory: "Fixtures"))
        let bytes = try Data(contentsOf: fixture)
        let copy = directory.appending(path: "original.store")
        try FileManager.default.copyItem(at: fixture, to: copy)
        let source = try autoreleasepool {
            let container = try V3TestSupport.container(WordNoteSchemaV1.self, url: copy)
            return try WordNoteSnapshotPayload.capture(from: container.mainContext)
        }
        let v2 = try WordNoteV1ToV2Migration.convert(source).payload
        let v3 = try WordNoteV2ToV3Migration.convert(v2, at: V3TestSupport.date)
        XCTAssertEqual(v3.content.content.terms, source.terms)
        XCTAssertEqual(v3.content.content.reviewEvents, source.reviewEvents)
        let primary = try XCTUnwrap(v3.cards.first { $0.termID.uuidString.lowercased() == "00000000-0000-4000-8000-000000000010" })
        XCTAssertEqual(primary.id.uuidString.lowercased(), "f6fbc903-637f-88eb-8052-14208db938c5")
        try roundTrip(v3, directory: directory)
        let reopened = try V3TestSupport.container(WordNoteSchemaV1.self, url: copy)
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: reopened.mainContext), source)
        XCTAssertEqual(try Data(contentsOf: fixture), bytes)
    }

    func testV3SnapshotRoundTripIncludesEveryEntityAndMetadataAfterDiskReopen() throws {
        let directory = try V3TestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var payload = try V3TestSupport.reviewedPayload()
        payload.cards[0].schedule.priorityRequestedAt = V3TestSupport.date.addingTimeInterval(1)
        payload.cards[0].schedule.introducedAt = V3TestSupport.date.addingTimeInterval(-86_400)
        payload.cards[0].schedule.relearningRepeatCount = 2
        payload.cards[0].schedule.buriedUntil = V3TestSupport.date.addingTimeInterval(3600)
        payload.cards[0].updatedAt = V3TestSupport.date.addingTimeInterval(2)
        payload.sessionItems[0].position = 7
        payload.sessionItems[0].updatedAt = V3TestSupport.date.addingTimeInterval(3)
        payload.sessions[0].updatedAt = V3TestSupport.date.addingTimeInterval(3)
        let eventIndex = try XCTUnwrap(payload.eventStates.firstIndex { $0.feedbackSemanticsVersion == 2 })
        payload.eventStates[eventIndex].invalidatedAt = V3TestSupport.date.addingTimeInterval(4)
        XCTAssertTrue([payload.counts.courses, payload.counts.inputRecords, payload.counts.candidates,
                       payload.counts.terms, payload.counts.reviewEvents, payload.counts.occurrences,
                       payload.counts.courseLinks, payload.counts.lookupEvents, payload.counts.cards,
                       payload.counts.sessions, payload.counts.sessionItems].allSatisfy { $0 > 0 })
        try roundTrip(payload, directory: directory)
    }

    func testActiveSessionCursorSurvivesDiskReopen() throws {
        let directory = try V3TestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var payload = try V3TestSupport.reviewedPayload()
        payload.sessionItems[0].status = .presented
        payload.sessionItems[0].availableAt = nil
        payload.sessions[0].status = .active
        payload.sessions[0].currentItemID = payload.sessionItems[0].id
        try roundTrip(payload, directory: directory)
    }

    func testDeletedCardTombstoneRemainsUnavailableAfterDiskReopen() throws {
        let directory = try V3TestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var payload = try V3TestSupport.reviewedPayload()
        let id = payload.sessionItems[0].originalCardID
        payload.cards.removeAll { $0.id == id }
        for i in payload.eventStates.indices where payload.eventStates[i].cardID == id { payload.eventStates[i].cardID = nil }
        payload.sessionItems[0].cardID = nil
        payload.sessionItems[0].status = .unavailable
        payload.sessionItems[0].completionOutcome = .unavailable
        payload.sessionItems[0].availableAt = nil
        payload.sessions[0].status = .completed
        payload.sessions[0].endedAt = V3TestSupport.date
        try roundTrip(payload, directory: directory)
    }

    func testClozeUnicodeRangeAndAnswersSurviveJSONAndDiskWithoutNormalization() throws {
        let directory = try V3TestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try roundTrip(V3TestSupport.clozePayload(), directory: directory)
    }

    func testCanonicalChecksumDoesNotDependOnFetchOrder() throws {
        var payload = try V3TestSupport.reviewedPayload()
        let checksum = try WordNoteSnapshotV3Codec.contentChecksum(payload)
        payload.content.content.terms.reverse()
        payload.content.content.reviewEvents.reverse()
        payload.content.recordStates.reverse()
        payload.termHistories.reverse()
        payload.cards.reverse()
        payload.sessions.reverse()
        payload.sessionItems.reverse()
        payload.eventStates.reverse()
        XCTAssertEqual(try WordNoteSnapshotV3Codec.contentChecksum(payload), checksum)
    }

    func testCodecRejectsDamageWrongCountsUnknownVersionsAndMissingFields() throws {
        let data = try WordNoteSnapshotV3Codec.encode(V3TestSupport.reviewedPayload(), kind: .beforeMigration)
        let original = try WordNoteSnapshotV3Codec.decode(data).document
        let changes: [(WordNoteSnapshotError, (inout WordNoteSnapshotV3Document) -> Void)] = [
            (.checksumMismatch, { $0.payload += " " }), (.countMismatch, { $0.counts.cards += 1 }),
            (.unsupportedSchema, { $0.sourceSchemaVersion = "4.0.0" }), (.unsupportedFormat, { $0.formatVersion = WordNoteSnapshotV3Codec.currentFormatVersion + 1 }),
            (.invalidValue, { $0.appVersion = String(repeating: "x", count: 129) })
        ]
        for (error, change) in changes {
            var value = original
            change(&value)
            XCTAssertThrowsError(try WordNoteSnapshotV3Codec.decode(JSONEncoder().encode(value))) {
                XCTAssertEqual($0 as? WordNoteSnapshotError, error)
            }
        }
        XCTAssertThrowsError(try WordNoteSnapshotV3Codec.decode(Data("{}".utf8))) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .invalidDocument)
        }
    }

    func testOldCodecsRejectV3AndVersionedReaderKeepsItsCompletePayload() throws {
        let payload = try V3TestSupport.reviewedPayload()
        let data = try WordNoteSnapshotV3Codec.encode(payload, kind: .manual)
        for decode in [WordNoteSnapshotCodec.decode as (Data) throws -> Any,
                       WordNoteSnapshotV2Codec.decode as (Data) throws -> Any] {
            XCTAssertThrowsError(try decode(data)) { XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedFormat) }
            var oldEnvelope = try JSONDecoder().decode(WordNoteSnapshotV3Document.self, from: data)
            oldEnvelope.formatVersion = 1
            XCTAssertThrowsError(try decode(JSONEncoder().encode(oldEnvelope))) {
                XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema)
            }
        }
        XCTAssertEqual(try WordNoteSnapshotReader.decode(data).payload, .v3(payload.canonicalized))
        XCTAssertTrue(TermModel.self == WordNoteSchemaV1.TermModel.self)
        XCTAssertEqual(WordNoteSchemaV1.models.count, 5)
        XCTAssertEqual(WordNoteSchemaV2.models.count, 8)
        XCTAssertEqual(WordNoteSchemaV3.models.count, 11)
        XCTAssertEqual(WordNoteMigrationPlan.schemas.count, 1)
        XCTAssertTrue(WordNoteMigrationPlan.stages.isEmpty)
    }

    func testImportRejectsOldOrNonemptyStoresAndDirtyEmptyContext() throws {
        let payload = try V3TestSupport.payload()
        for version in [WordNoteSchemaV1.self as any VersionedSchema.Type, WordNoteSchemaV2.self] {
            let old = try V3TestSupport.container(version)
            XCTAssertThrowsError(try payload.populateEmptyStore(old.mainContext)) {
                XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema)
            }
            XCTAssertThrowsError(try WordNoteSnapshotV3Payload.capture(from: old.mainContext)) {
                XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema)
            }
        }
        let destination = try V3TestSupport.container()
        destination.mainContext.insert(WordNoteSchemaV3.CourseModel(courseName: "Unsaved"))
        XCTAssertThrowsError(try payload.populateEmptyStore(destination.mainContext)) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .destinationNotEmpty)
        }
        destination.mainContext.rollback()
        try payload.populateEmptyStore(destination.mainContext)
        XCTAssertThrowsError(try payload.populateEmptyStore(destination.mainContext)) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .destinationNotEmpty)
        }
        XCTAssertThrowsError(try WordNoteSnapshotV2Payload.capture(from: destination.mainContext)) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema)
        }
        XCTAssertEqual(try WordNoteSnapshotV3Payload.capture(from: destination.mainContext, preferences: payload.content.content.preferences), payload)
    }

    func testInvalidPayloadFailsBeforeAnyRowsAreInserted() throws {
        let destination = try V3TestSupport.container()
        var payload = try V3TestSupport.payload()
        payload.cards[0].termID = UUID()
        XCTAssertThrowsError(try payload.populateEmptyStore(destination.mainContext))
        XCTAssertEqual(try WordNoteSnapshotV3Payload.capture(from: destination.mainContext).counts.total, 0)
        XCTAssertFalse(destination.mainContext.hasChanges)
    }

    func testFailureBeforeSaveRollsBackAllElevenEntitiesAndAllowsRetry() throws {
        enum Injected: Error { case saveFailed }
        let destination = try V3TestSupport.container()
        let payload = try V3TestSupport.reviewedPayload()
        XCTAssertThrowsError(try payload.populateEmptyStore(destination.mainContext, beforeSave: { throw Injected.saveFailed }))
        XCTAssertEqual(try WordNoteSnapshotV3Payload.capture(from: destination.mainContext).counts.total, 0)
        XCTAssertFalse(destination.mainContext.hasChanges)
        try payload.populateEmptyStore(destination.mainContext)
        XCTAssertEqual(try WordNoteSnapshotV3Payload.capture(from: destination.mainContext, preferences: payload.content.content.preferences), payload.canonicalized)
    }

    func testCorruptPersistentJSONAndRawEnumFailCaptureWithoutFallback() throws {
        let destination = try V3TestSupport.container()
        try V3TestSupport.reviewedPayload().populateEmptyStore(destination.mainContext)
        let session = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewSessionModel>()).first)
        let before = session.scopeSnapshotJSON
        session.scopeSnapshotJSON = "{}"
        XCTAssertThrowsError(try WordNoteSnapshotV3Payload.capture(from: destination.mainContext)) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .invalidDocument)
        }
        session.scopeSnapshotJSON = before
        let card = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewCardModel>()).first)
        card.phaseRaw = "unknown"
        XCTAssertThrowsError(try WordNoteSnapshotV3Payload.capture(from: destination.mainContext)) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .invalidEnum)
        }
    }

    private func roundTrip(_ payload: WordNoteSnapshotV3Payload, directory: URL) throws {
        let data = try WordNoteSnapshotV3Codec.encode(payload, kind: .beforeMigration)
        let decoded = try WordNoteSnapshotV3Codec.decode(data)
        XCTAssertEqual(decoded.payload, payload.canonicalized)
        let url = directory.appending(path: "v3.store")
        try autoreleasepool {
            let destination = try V3TestSupport.container(url: url)
            try decoded.payload.populateEmptyStore(destination.mainContext)
            XCTAssertEqual(try WordNoteSnapshotV3Payload.capture(from: destination.mainContext, preferences: payload.content.content.preferences), payload.canonicalized)
        }
        let reopened = try V3TestSupport.container(url: url)
        XCTAssertEqual(try WordNoteSnapshotV3Payload.capture(from: reopened.mainContext, preferences: payload.content.content.preferences), payload.canonicalized)
    }
}
