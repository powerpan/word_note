import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
enum V3QuestionTestSupport {
    static let now = V3SessionTestSupport.now
    static let zone = V3SessionTestSupport.zone
    static func container(source: String = "A quick response needs quick thinking.") throws -> ModelContainer {
        let container = try V3SessionTestSupport.container(count: 1)
        let term = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()).first)
        term.term = "quick"
        term.normalizedTerm = "quick"
        term.chineseMeaning = "quick：快速的；敏捷的"
        term.exampleSentence = "A quick AI example is not an original source."
        let record = WordNoteSchemaV3.InputRecordModel(rawText: source, createdAt: now, updatedAt: now)
        let occurrence = WordNoteSchemaV3.TermOccurrenceModel(termID: term.id, captureID: record.captureID,
            sourceRecordID: record.id, rawTextSnapshot: source, occurredAt: now, capturedVia: .legacy, legacy: true, createdAt: now)
        container.mainContext.insert(record)
        container.mainContext.insert(occurrence)
        try container.mainContext.save()
        _ = try V3SessionTestSupport.snapshot(container)
        return container
    }

    static func draft(_ service: WordNoteV3ContentService, container: ModelContainer) throws -> WordNoteV3ClozeDraft {
        let payload = try V3SessionTestSupport.snapshot(container)
        let source = try XCTUnwrap(payload.content.occurrences.first)
        let ranges = try service.clozeSuggestions(termID: source.termID, occurrenceID: source.id)
        let range = try XCTUnwrap(ranges.first)
        return try service.previewClozeCard(termID: source.termID, occurrenceID: source.id, selectedRange: range)
    }

    @discardableResult
    static func create(_ service: WordNoteV3ContentService, container: ModelContainer) throws -> WordNoteSnapshotV3Payload.Card {
        try service.createClozeCard(draft(service, container: container), studyTimeZoneID: zone, at: now)
    }
}

@MainActor
final class WordNoteV3ClozeCardTests: XCTestCase {
    private typealias Support = V3QuestionTestSupport
    private typealias Payload = WordNoteSnapshotV3Payload

    func testPreviewIsReadOnlyAndCreationIsIndependentAndIdempotent() throws {
        let container = try Support.container()
        var saves = 0
        let service = try WordNoteV3ContentService(container: container, beforeSave: { _ in saves += 1 })
        let before = try V3SessionTestSupport.snapshot(container)
        let draft = try Support.draft(service, container: container)
        XCTAssertEqual(draft.preview.prompt, "A ____ response needs ____ thinking.")
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(try V3SessionTestSupport.snapshot(container), before)
        let card = try service.createClozeCard(draft, studyTimeZoneID: Support.zone, at: Support.now)
        XCTAssertEqual(card.schedule, .init())
        let after = try V3SessionTestSupport.snapshot(container)
        XCTAssertEqual(after.cards.first { $0.mode == .englishToChinese }, before.cards[0])
        XCTAssertEqual(after.content.content.reviewEvents, before.content.content.reviewEvents)
        XCTAssertEqual(try service.createClozeCard(draft, studyTimeZoneID: Support.zone, at: Support.now), card)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try V3SessionTestSupport.snapshot(container), after)
    }

    func testDuplicateTargetWithDifferentIDsIsRejected() throws {
        let container = try Support.container()
        let service = try WordNoteV3ContentService(container: container)
        _ = try Support.create(service, container: container)
        let fresh = try Support.draft(service, container: container)
        XCTAssertThrowsError(try service.createClozeCard(fresh, studyTimeZoneID: Support.zone, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .actionConflict)
        }
    }

    func testDraftRejectsTermSourceRecordAndMetadataChangesEvenWithoutRevisionBump() throws {
        for mutation in 0..<4 {
            let container = try Support.container()
            let service = try WordNoteV3ContentService(container: container)
            let draft = try Support.draft(service, container: container)
            switch mutation {
            case 0: try container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()).first?.chineseMeaning = "更改"
            case 1: try container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermOccurrenceModel>()).first?.note = "changed"
            case 2: try container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.InputRecordModel>()).first?.note = "changed"
            default: try container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.InputRecordModel>()).first?.revision += 1
            }
            try container.mainContext.save()
            let before = try V3SessionTestSupport.snapshot(container)
            XCTAssertThrowsError(try service.createClozeCard(draft, studyTimeZoneID: Support.zone, at: Support.now))
            XCTAssertEqual(try V3SessionTestSupport.snapshot(container), before)
        }
    }

    func testMissingOriginalAndMismatchedCaptureCannotUseAnAIExampleAsSource() throws {
        for hasRecord in [true, false] {
            let container = try Support.container()
            let occurrence = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermOccurrenceModel>()).first)
            if hasRecord { occurrence.rawTextSnapshot = "A different quick AI example." }
            else { occurrence.sourceRecordID = nil }
            try container.mainContext.save()
            let service = try WordNoteV3ContentService(container: container)
            XCTAssertThrowsError(try service.clozeSuggestions(termID: occurrence.termID, occurrenceID: occurrence.id)) {
                XCTAssertEqual($0 as? ReviewQuestionError, .invalidSource)
            }
        }
    }

    func testChineseLookupCannotBeUsedAsEnglishClozeSource() throws {
        let container = try Support.container(source: "快速的英文 quick")
        let service = try WordNoteV3ContentService(container: container)
        XCTAssertThrowsError(try Support.draft(service, container: container)) {
            XCTAssertEqual($0 as? ReviewQuestionError, .invalidSource)
        }
    }

    func testCreateFailureRollsBackCardAndTermRevisionAndCanRetrySameDraft() throws {
        let container = try Support.container()
        var fail = true
        let service = try WordNoteV3ContentService(container: container, beforeSave: { _ in if fail { throw V3ReviewTestSupport.Failure.save } })
        let draft = try Support.draft(service, container: container)
        let before = try V3SessionTestSupport.snapshot(container)
        XCTAssertThrowsError(try service.createClozeCard(draft, studyTimeZoneID: Support.zone, at: Support.now))
        XCTAssertEqual(try V3SessionTestSupport.snapshot(container), before)
        fail = false
        XCTAssertNoThrow(try service.createClozeCard(draft, studyTimeZoneID: Support.zone, at: Support.now))
    }

    func testEditingSourceInvalidatesTargetAndPresentedItemWithoutFabricatingFeedback() throws {
        let container = try Support.container()
        let content = try WordNoteV3ContentService(container: container)
        let card = try Support.create(content, container: container)
        let review = try WordNoteV3ReviewService(container: container)
        let session = try review.startSession(scope: V3SessionTestSupport.scope(newCards: true, mode: .contextCloze), at: Support.now)
        let lease = try review.acquireLease(sessionID: session.session.id, ownerID: UUID())
        _ = try review.presentNextCard(lease: lease, expectedRevision: session.session.revision, at: Support.now)
        let before = try V3SessionTestSupport.snapshot(container)
        try content.reviseOccurrenceText(before.content.occurrences[0], expectedTermRevision: before.content.termStates[0].revision,
            rawText: "An edited quick source.", at: Support.now.addingTimeInterval(1))
        let after = try V3SessionTestSupport.snapshot(container)
        let changed = try XCTUnwrap(after.cards.first { $0.id == card.id })
        XCTAssertEqual(changed.schedule.phase, .suspended)
        XCTAssertNil(changed.schedule.nextReviewAt)
        XCTAssertNotNil(changed.clozeTarget?.sourceChangedAt)
        XCTAssertNil(changed.clozeTarget?.sourceDeletedAt)
        XCTAssertEqual(changed.clozeTarget?.answer, "")
        XCTAssertEqual(changed.clozeTarget?.characterCount, 0)
        XCTAssertEqual(after.sessionItems[0].status, .unavailable)
        XCTAssertEqual(after.sessions[0].status, .completed)
        XCTAssertEqual(after.content.content.inputRecords, before.content.content.inputRecords)
        XCTAssertEqual(after.eventStates, before.eventStates)
        XCTAssertThrowsError(try review.questionFront(sessionID: session.session.id))
        XCTAssertThrowsError(try Support.draft(content, container: container))
    }

    func testSourceEditFailureRollsBackAndNoOpEditDoesNotSuspend() throws {
        let container = try Support.container()
        let content = try WordNoteV3ContentService(container: container)
        _ = try Support.create(content, container: container)
        let before = try V3SessionTestSupport.snapshot(container)
        let service = try WordNoteV3ContentService(container: container, beforeSave: { _ in throw V3ReviewTestSupport.Failure.save })
        XCTAssertNoThrow(try service.reviseOccurrenceText(before.content.occurrences[0], expectedTermRevision: before.content.termStates[0].revision,
            rawText: before.content.occurrences[0].rawTextSnapshot, at: Support.now))
        XCTAssertThrowsError(try service.reviseOccurrenceText(before.content.occurrences[0], expectedTermRevision: before.content.termStates[0].revision,
            rawText: "An edited quick source.", at: Support.now))
        XCTAssertEqual(try V3SessionTestSupport.snapshot(container), before)
    }

    func testChangedSourceTombstoneCannotRetainAnswerLoseSourceOrBecomeActive() throws {
        let container = try Support.container()
        let content = try WordNoteV3ContentService(container: container)
        let card = try Support.create(content, container: container)
        var payload = try V3SessionTestSupport.snapshot(container)
        try content.reviseOccurrenceText(payload.content.occurrences[0], expectedTermRevision: payload.content.termStates[0].revision,
            rawText: "An edited quick source.", at: Support.now)
        payload = try V3SessionTestSupport.snapshot(container)
        let index = try XCTUnwrap(payload.cards.firstIndex { $0.id == card.id })
        let mutations: [(inout WordNoteSnapshotV3Payload) -> Void] = [
            { $0.cards[index].clozeTarget?.answer = "quick" },
            { $0.cards[index].clozeTarget?.sourceDeletedAt = Support.now },
            { $0.content.occurrences = [] },
            { $0.cards[index].schedule.phase = .new },
            { $0.cards[index].schedule.priorityRequestedAt = Support.now },
            { $0.cards[index].clozeTarget?.sourceChangedAt = .init(timeIntervalSince1970: .infinity) }
        ]
        for mutate in mutations {
            var invalid = payload
            mutate(&invalid)
            XCTAssertThrowsError(try invalid.validate())
        }
    }

    func testDeletingInputRecordPreservesExistingClozeButDisablesNewProposals() throws {
        let container = try Support.container()
        let service = try WordNoteV3ContentService(container: container)
        let card = try Support.create(service, container: container)
        let before = try V3SessionTestSupport.snapshot(container)
        try service.deleteInputRecord(before.content.content.inputRecords[0].id, expectedRevision: 0, at: Support.now)
        let after = try V3SessionTestSupport.snapshot(container)
        XCTAssertEqual(after.cards.first { $0.id == card.id }, card)
        XCTAssertNoThrow(try ReviewQuestionContent.front(card: card, term: after.content.content.terms[0], occurrence: after.content.occurrences[0]))
        XCTAssertThrowsError(try Support.draft(service, container: container))
    }

    func testEditedSourceTombstoneRoundTripsAndCanThenBeDeleted() async throws {
        let container = try Support.container()
        let service = try WordNoteV3ContentService(container: container)
        let card = try Support.create(service, container: container)
        var payload = try V3SessionTestSupport.snapshot(container)
        try service.reviseOccurrenceText(payload.content.occurrences[0], expectedTermRevision: payload.content.termStates[0].revision,
            rawText: "An edited quick source.", at: Support.now)
        payload = try V3SessionTestSupport.snapshot(container)
        let encoded = try WordNoteSnapshotV3Codec.encode(payload, kind: .manual)
        let decoded = try WordNoteSnapshotV3Codec.decode(encoded)
        XCTAssertEqual(decoded.document.formatVersion, 5)
        XCTAssertEqual(decoded.payload, payload)
        let harness = V3RecoveryHarness(directory: try V3TestSupport.directory())
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        _ = try await harness.seed(.v3(decoded.payload))
        let reopened = try harness.store.open()
        XCTAssertEqual(try harness.capture(reopened), .v3(payload))
        let restored = try WordNoteV3ContentService(container: reopened.container)
        try restored.deleteOccurrence(payload.content.occurrences[0].id, expectedTermRevision: payload.content.termStates[0].revision, at: Support.now)
        let final = try V3SessionTestSupport.snapshot(reopened.container)
        let target = try XCTUnwrap(final.cards.first { $0.id == card.id }?.clozeTarget)
        XCTAssertNotNil(target.sourceDeletedAt)
        XCTAssertNil(target.sourceChangedAt)
    }

    func testChangedSourceMarkerRequiresFormatFourInBackupsAndEvidence() async throws {
        let container = try Support.container()
        let service = try WordNoteV3ContentService(container: container)
        _ = try Support.create(service, container: container)
        let before = try V3SessionTestSupport.snapshot(container)
        try service.reviseOccurrenceText(before.content.occurrences[0], expectedTermRevision: before.content.termStates[0].revision,
            rawText: "An edited quick source.", at: Support.now)
        let payload = try V3SessionTestSupport.snapshot(container)
        var document = try JSONDecoder().decode(WordNoteSnapshotV3Document.self, from: WordNoteSnapshotV3Codec.encode(payload, kind: .manual))
        for version in 1...3 {
            document.formatVersion = version
            XCTAssertThrowsError(try WordNoteSnapshotReader.decode(JSONEncoder().encode(document)))
        }
        let directory = try V3TestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WordNoteV3RepairEvidenceVault(directoryURL: directory)
        let saved = try await vault.create(payload, generation: .init(id: UUID()), at: Support.now)
        let initial = try await vault.read(id: saved.summary.id)
        XCTAssertEqual(initial.payload, payload)
        let url = await vault.fileURL(saved.summary.id)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for version in 1...3 {
            object["evidenceFormatVersion"] = version
            try PrivateFileIO.write(JSONSerialization.data(withJSONObject: object), to: url)
            do { _ = try await vault.read(id: saved.summary.id); XCTFail("Downlabeling must fail") }
            catch { XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedFormat) }
        }
    }
}
