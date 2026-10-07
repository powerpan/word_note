import CryptoKit
import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteSnapshotTests: XCTestCase {
    func testSnapshotDTOsCoverEveryPersistedV1Field() throws {
        let payload = try samplePayload()
        let dtoFields: [String: Set<String>] = [
            "CourseModel": fields(payload.courses[0]),
            "InputRecordModel": fields(payload.inputRecords[0]),
            "CandidateTermModel": fields(payload.candidates[0]),
            "TermModel": fields(payload.terms[0]),
            "ReviewEventModel": fields(payload.reviewEvents[0])
        ]
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        XCTAssertEqual(Set(schema.entities.map(\.name)), Set(dtoFields.keys))
        for entity in schema.entities {
            XCTAssertEqual(Set(entity.properties.map(\.name)), dtoFields[entity.name], entity.name)
        }
    }

    private func fields<T>(_ value: T) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label))
    }

    func testCompleteV1PayloadRoundTripsEveryField() throws {
        var payload = try samplePayload()
        let date = Date(timeIntervalSinceReferenceDate: 812_345_678.125)
        payload.preferences = .init(appearance: "dark", defaultSource: "paper")
        payload.courses[0].courseCode = "CS-50"
        payload.courses[0].instructor = "Fixture Instructor"
        payload.courses[0].semester = "2026-Fall"
        payload.courses[0].courseDescription = "Synthetic course only."
        payload.courses[0].updatedAt = date
        payload.inputRecords[0].normalizedText = "preserve the original normalized value"
        payload.inputRecords[0].note = "原文筆記\n第二行"
        payload.inputRecords[0].aiErrorSummary = "Synthetic timeout"
        payload.inputRecords[0].sentenceMeaning = "完整句子含義"
        payload.inputRecords[0].analyzedAt = date
        payload.inputRecords[0].statusRaw = "analyzing"
        payload.candidates[0].normalizedTerm = "preserve candidate normalization"
        payload.candidates[0].reason = "Useful expression."
        payload.candidates[0].englishDefinition = "A full candidate definition."
        payload.candidates[0].aiContextExplanation = "Technical sense."
        payload.candidates[0].exampleSentence = "A complete example."
        payload.candidates[0].relatedTerms = ["generalization", "regularization"]
        payload.candidates[0].statusRaw = "saved"
        payload.candidates[1].statusRaw = "ignored"
        payload.terms[0].normalizedTerm = "preserve term normalization"
        payload.terms[0].aiContextExplanation = "Independent technical meaning."
        payload.terms[0].exampleSentence = "An example with a comma, and a quote: \"word\"."
        payload.terms[0].contextSentence = "Private learning context in an explicitly exported snapshot."
        payload.terms[0].sourceRecordID = payload.inputRecords[0].id
        payload.terms[0].tags = ["tag one", "標籤", ""]
        payload.terms[0].reviewIntervalDays = 7
        payload.terms[0].correctStreak = 2
        payload.terms[0].reviewCount = 3
        payload.terms[0].wrongCount = 10 // Legacy lookup counts can exceed the review count.
        payload.terms[0].duplicateHitCount = 9
        payload.terms[0].lastDuplicateHitAt = date
        payload.terms[0].lastReviewedAt = date
        payload.terms[0].nextReviewAt = date.addingTimeInterval(12.5)
        payload.reviewEvents[0].modeRaw = "chineseToEnglish"
        payload.reviewEvents[0].feedbackRaw = "hard"
        payload.reviewEvents[0].previousNextReviewAt = date
        payload.reviewEvents[0].newNextReviewAt = date.addingTimeInterval(86_400)
        payload.reviewEvents[0].reviewedAt = date
        let encoded = try WordNoteSnapshotCodec.encode(payload, kind: .manual, createdAt: date)
        let decoded = try WordNoteSnapshotCodec.decode(encoded)
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertEqual(decoded.document.createdAt, date)
        XCTAssertEqual(decoded.document.counts.total, 13)

        let container = try makeContainer()
        try decoded.payload.populateEmptyStore(container.mainContext)
        XCTAssertEqual(
            try WordNoteSnapshotPayload.capture(from: container.mainContext, preferences: payload.preferences), payload
        )
    }

    func testEmptySnapshotIsValid() throws {
        let container = try makeContainer()
        let payload = try WordNoteSnapshotPayload.capture(from: container.mainContext)
        let decoded = try WordNoteSnapshotCodec.decode(WordNoteSnapshotCodec.encode(payload, kind: .manual))
        XCTAssertEqual(decoded.document.counts.total, 0)
    }

    func testFrozenV1CanBeBackedUpAndRestoredIntoNewPersistentStore() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "snapshot-v1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "source.store")
        let resource = try XCTUnwrap(Bundle.module.url(forResource: "v1", withExtension: "store", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: resource, to: sourceURL)
        let source = try makeContainer(url: sourceURL)
        let payload = try WordNoteSnapshotPayload.capture(from: source.mainContext)
        let decoded = try WordNoteSnapshotCodec.decode(WordNoteSnapshotCodec.encode(payload, kind: .beforeMigration))
        let destinationURL = directory.appending(path: "restored.store")
        try autoreleasepool {
            let destination = try makeContainer(url: destinationURL)
            try decoded.payload.populateEmptyStore(destination.mainContext)
        }
        let reopened = try makeContainer(url: destinationURL)
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: reopened.mainContext), payload)
        XCTAssertEqual(try DataIntegrityService(modelContext: reopened.mainContext).repairDanglingReferences().repairedItemCount, 0)
    }

    func testRestoreRefusesNonEmptyDestinationWithoutChangingIt() throws {
        let destination = try makeContainer()
        try WordNoteTestFixture.populated.populate(destination.mainContext)
        let before = try WordNoteSnapshotPayload.capture(from: destination.mainContext)
        XCTAssertThrowsError(try samplePayload().populateEmptyStore(destination.mainContext)) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .destinationNotEmpty)
        }
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: destination.mainContext), before)
    }

    func testChecksumCoversExactPayloadBytes() throws {
        var document = try sampleDocument()
        document.payload += " "
        XCTAssertThrowsError(try WordNoteSnapshotCodec.decode(JSONEncoder().encode(document))) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .checksumMismatch)
        }
    }

    func testOuterJSONFormattingDoesNotInvalidatePayloadChecksum() throws {
        let document = try sampleDocument()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        XCTAssertEqual(try WordNoteSnapshotCodec.decode(encoder.encode(document)).payload, try samplePayload())
    }

    func testRejectsNewerFormatAndNewerSchema() throws {
        var document = try sampleDocument()
        document.formatVersion = 2
        XCTAssertThrowsError(try WordNoteSnapshotCodec.decode(JSONEncoder().encode(document))) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedFormat)
        }
        document.formatVersion = 1
        document.sourceSchemaVersion = "2.0.0"
        XCTAssertThrowsError(try WordNoteSnapshotCodec.decode(JSONEncoder().encode(document))) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema)
        }
    }

    func testRejectsIncorrectAndOverflowingMetadataCounts() throws {
        var document = try sampleDocument()
        document.counts.terms = Int.max
        XCTAssertThrowsError(try WordNoteSnapshotCodec.decode(JSONEncoder().encode(document))) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .countMismatch)
        }
    }

    func testRejectsDuplicateIDsInEveryEntityType() throws {
        let mutations: [(inout WordNoteSnapshotPayload) -> Void] = [
            { $0.courses.append($0.courses[0]) },
            { $0.inputRecords.append($0.inputRecords[0]) },
            { $0.candidates.append($0.candidates[0]) },
            { $0.terms.append($0.terms[0]) },
            { $0.reviewEvents.append($0.reviewEvents[0]) }
        ]
        for mutate in mutations {
            var payload = try samplePayload()
            mutate(&payload)
            XCTAssertThrowsError(try payload.validate()) {
                XCTAssertEqual($0 as? WordNoteSnapshotError, .duplicateID)
            }
        }
    }

    func testRejectsEveryDanglingReference() throws {
        let mutations: [(inout WordNoteSnapshotPayload) -> Void] = [
            { $0.inputRecords[0].courseID = UUID() },
            { $0.candidates[0].inputRecordID = UUID() },
            { $0.terms[0].courseID = UUID() },
            { $0.terms[0].sourceRecordID = UUID() },
            { $0.reviewEvents[0].termID = UUID() }
        ]
        for mutate in mutations {
            var payload = try samplePayload()
            mutate(&payload)
            XCTAssertThrowsError(try payload.validate()) {
                XCTAssertEqual($0 as? WordNoteSnapshotError, .missingReference)
            }
        }
    }

    func testValidChecksumDoesNotBypassSemanticValidation() throws {
        var payload = try samplePayload()
        payload.terms[0].importanceRaw = "unknown-future-importance"
        var document = try sampleDocument()
        let payloadData = try JSONEncoder().encode(payload)
        document.payload = String(decoding: payloadData, as: UTF8.self)
        document.payloadChecksum = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
        XCTAssertThrowsError(try WordNoteSnapshotCodec.decode(JSONEncoder().encode(document))) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .invalidEnum)
        }
    }

    func testRejectsInvalidDatesCountersConfidenceAndPreferences() throws {
        let mutations: [(inout WordNoteSnapshotPayload) -> Void] = [
            { $0.terms[0].wrongCount = -1 },
            { $0.terms[0].reviewIntervalDays = Int.max },
            { $0.candidates[0].confidence = 1.1 },
            { $0.candidates[0].confidence = .nan },
            { $0.reviewEvents[0].reviewedAt = Date(timeIntervalSince1970: .infinity) }
        ]
        for mutate in mutations {
            var payload = try samplePayload()
            mutate(&payload)
            XCTAssertThrowsError(try payload.validate()) {
                XCTAssertEqual($0 as? WordNoteSnapshotError, .invalidValue)
            }
        }
        var payload = try samplePayload()
        payload.preferences.appearance = "unknown"
        XCTAssertThrowsError(try payload.validate()) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .invalidEnum)
        }
    }

    func testLegacyInvalidEnglishSubjectIsNotSilentlyDeletedDuringRestore() throws {
        var payload = try samplePayload()
        payload.terms[0].term = "舊資料中文主體"
        payload.terms[0].normalizedTerm = "舊資料中文主體"
        let destination = try makeContainer()
        try payload.populateEmptyStore(destination.mainContext)
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: destination.mainContext), payload)
    }

    func testSizeLimitsAndInvalidJSON() throws {
        XCTAssertThrowsError(try WordNoteSnapshotCodec.decode(Data(repeating: 0, count: WordNoteSnapshotCodec.maximumDocumentBytes + 1))) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .sizeLimit)
        }
        XCTAssertThrowsError(try WordNoteSnapshotCodec.decode(Data("not-json".utf8))) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .invalidDocument)
        }
        var payload = try samplePayload()
        payload.terms[0].chineseMeaning = String(repeating: "x", count: WordNoteSnapshotPayload.maximumTextCharacters + 1)
        XCTAssertThrowsError(try payload.validate()) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .sizeLimit)
        }
        payload = try samplePayload()
        payload.reviewEvents = Array(repeating: payload.reviewEvents[0], count: WordNoteSnapshotPayload.maximumEntityCount)
        XCTAssertThrowsError(try payload.validate()) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .sizeLimit)
        }
    }

    func testPreferencesAreAnExplicitNonSecretWhitelist() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(WordNoteSnapshotPayload.Preferences())) as? [String: String])
        XCTAssertEqual(Set(object.keys), ["appearance", "defaultSource"])
        XCTAssertFalse(try sampleDocument().payload.contains("DEEPSEEK_API_KEY"))
    }

    func testContentChecksumIgnoresEnvelopeMetadataButDetectsDataChange() throws {
        var payload = try samplePayload()
        let first = try WordNoteSnapshotCodec.decode(WordNoteSnapshotCodec.encode(payload, kind: .manual))
        let second = try WordNoteSnapshotCodec.decode(WordNoteSnapshotCodec.encode(payload, kind: .automatic))
        XCTAssertEqual(first.document.payloadChecksum, second.document.payloadChecksum)
        XCTAssertNotEqual(first.document.snapshotID, second.document.snapshotID)
        payload.terms[0].chineseMeaning = "A changed definition."
        XCTAssertNotEqual(try WordNoteSnapshotCodec.contentChecksum(payload), first.document.payloadChecksum)
    }

    private func samplePayload() throws -> WordNoteSnapshotPayload {
        let container = try makeContainer()
        try WordNoteTestFixture.populated.populate(container.mainContext)
        return try WordNoteSnapshotPayload.capture(from: container.mainContext)
    }

    private func sampleDocument() throws -> WordNoteSnapshotDocument {
        try WordNoteSnapshotCodec.decode(WordNoteSnapshotCodec.encode(samplePayload(), kind: .manual)).document
    }

    private func makeContainer(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let configuration = url.map { ModelConfiguration("SnapshotTests", schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, migrationPlan: WordNoteMigrationPlan.self, configurations: [configuration])
    }
}
