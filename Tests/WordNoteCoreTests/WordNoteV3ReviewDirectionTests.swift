import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3ReviewDirectionTests: XCTestCase {
    private typealias Support = V3QuestionTestSupport

    func testNewDirectionStartsNewWithoutCopyingSiblingAbilityAndRequiresOptIn() throws {
        let container = try Support.container()
        let service = try WordNoteV3ContentService(container: container)
        let before = try V3SessionTestSupport.snapshot(container)
        let card = try service.enableReviewDirection(termID: before.content.content.terms[0].id, expectedTermRevision: 0,
            mode: .chineseToEnglish, studyTimeZoneID: Support.zone, at: Support.now)
        XCTAssertEqual(card.schedule, .init())
        let after = try V3SessionTestSupport.snapshot(container)
        XCTAssertEqual(after.cards.first { $0.mode == .englishToChinese }, before.cards[0])
        let review = try WordNoteV3ReviewService(container: container)
        XCTAssertThrowsError(try review.startSession(scope: V3SessionTestSupport.scope(mode: .chineseToEnglish), at: Support.now))
        let session = try review.startSession(scope: V3SessionTestSupport.scope(newCards: true, mode: .chineseToEnglish), at: Support.now)
        XCTAssertEqual(session.items.map(\.cardID), [card.id])
    }

    func testExistingDirectionIsReadOnlyAndRevisionAndModeGuardsApply() throws {
        let container = try Support.container()
        var saves = 0
        let content = try WordNoteV3ContentService(container: container, beforeSave: { _ in saves += 1 })
        let before = try V3SessionTestSupport.snapshot(container)
        let termID = before.content.content.terms[0].id
        XCTAssertEqual(try content.enableReviewDirection(termID: termID, expectedTermRevision: 0, mode: .englishToChinese,
            studyTimeZoneID: Support.zone, at: Support.now), before.cards[0])
        XCTAssertThrowsError(try content.enableReviewDirection(termID: termID, expectedTermRevision: 99, mode: .chineseToEnglish,
            studyTimeZoneID: Support.zone, at: Support.now))
        XCTAssertThrowsError(try content.enableReviewDirection(termID: termID, expectedTermRevision: 0, mode: .contextCloze,
            studyTimeZoneID: Support.zone, at: Support.now))
        XCTAssertThrowsError(try content.enableReviewDirection(termID: termID, expectedTermRevision: 0, mode: .chineseToEnglish,
            studyTimeZoneID: "unknown-zone", at: Support.now))
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(try V3SessionTestSupport.snapshot(container), before)
    }

    func testNoChineseMeaningCannotEnableChineseRecall() throws {
        for meaning: String? in [nil, "", "quick response"] {
            let container = try Support.container()
            let term = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()).first)
            term.chineseMeaning = meaning
            try container.mainContext.save()
            let content = try WordNoteV3ContentService(container: container)
            let before = try V3SessionTestSupport.snapshot(container)
            XCTAssertThrowsError(try content.enableReviewDirection(termID: term.id, expectedTermRevision: 0, mode: .chineseToEnglish,
                studyTimeZoneID: Support.zone, at: Support.now)) {
                XCTAssertEqual($0 as? ReviewQuestionError, .missingAnswer)
            }
            XCTAssertEqual(try V3SessionTestSupport.snapshot(container), before)
        }
    }

    func testCreatingDirectionAndClozeAfterPresentationInheritsBurial() throws {
        for didReveal in [false, true] {
            let container = try Support.container()
            let review = try WordNoteV3ReviewService(container: container)
            let (lease, source) = try V3SessionTestSupport.startPresented(review)
            if didReveal { _ = try review.revealAnswer(source, lease: lease, at: Support.now) }
            let content = try WordNoteV3ContentService(container: container)
            let chinese = try content.enableReviewDirection(termID: source.term.id, expectedTermRevision: source.termState.revision,
                mode: .chineseToEnglish, studyTimeZoneID: Support.zone, at: Support.now)
            let cloze = try Support.create(content, container: container)
            let until = try ReviewStudyDay(containing: Support.now, timeZoneID: Support.zone).end
            XCTAssertEqual(chinese.schedule.buriedUntil, until)
            XCTAssertEqual(cloze.schedule.buriedUntil, until)
            XCTAssertNil(chinese.schedule.introducedAt)
            XCTAssertNil(cloze.schedule.introducedAt)
        }
    }

    func testPendingUnpresentedSiblingDoesNotPreventNewDirection() throws {
        let container = try Support.container()
        let review = try WordNoteV3ReviewService(container: container)
        _ = try review.startSession(scope: V3SessionTestSupport.scope(), at: Support.now)
        let content = try WordNoteV3ContentService(container: container)
        let term = try V3SessionTestSupport.snapshot(container).content.content.terms[0]
        let card = try content.enableReviewDirection(termID: term.id, expectedTermRevision: 0, mode: .chineseToEnglish,
            studyTimeZoneID: Support.zone, at: Support.now)
        XCTAssertNil(card.schedule.buriedUntil)
    }

    func testDeletingRevealedCardAndReopeningCannotBypassNewDirectionsBurial() throws {
        let container = try Support.container()
        let review = try WordNoteV3ReviewService(container: container)
        let (lease, source) = try V3SessionTestSupport.startPresented(review)
        let revealed = try review.revealAnswer(source, lease: lease, at: Support.now)
        let content = try WordNoteV3ContentService(container: container)
        try content.deleteReviewCard(source.card.id, expectedRevision: revealed.card.revision, at: Support.now)
        let payload = try V3SessionTestSupport.snapshot(container)
        let reopened = try V3ReviewTestSupport.seeded(WordNoteSnapshotV3Codec.decode(WordNoteSnapshotV3Codec.encode(payload, kind: .manual)).payload)
        let restored = try WordNoteV3ContentService(container: reopened)
        let card = try restored.enableReviewDirection(termID: source.term.id, expectedTermRevision: payload.content.termStates[0].revision,
            mode: .chineseToEnglish, studyTimeZoneID: Support.zone, at: Support.now)
        XCTAssertEqual(card.schedule.buriedUntil, try ReviewStudyDay(containing: Support.now, timeZoneID: Support.zone).end)
    }

    func testDeletingUnpresentedCardDoesNotInventExposure() throws {
        let container = try Support.container()
        let review = try WordNoteV3ReviewService(container: container)
        _ = try review.startSession(scope: V3SessionTestSupport.scope(), at: Support.now)
        let payload = try V3SessionTestSupport.snapshot(container)
        let content = try WordNoteV3ContentService(container: container)
        try content.deleteReviewCard(payload.cards[0].id, expectedRevision: payload.cards[0].revision, at: Support.now)
        let after = try V3SessionTestSupport.snapshot(container)
        let card = try content.enableReviewDirection(termID: payload.cards[0].termID, expectedTermRevision: after.content.termStates[0].revision,
            mode: .chineseToEnglish, studyTimeZoneID: Support.zone, at: Support.now)
        XCTAssertNil(card.schedule.buriedUntil)
    }

    func testExactLookupRecreatingDeletedPrimaryAlsoInheritsExposure() throws {
        let container = try Support.container()
        let review = try WordNoteV3ReviewService(container: container)
        let (lease, source) = try V3SessionTestSupport.startPresented(review)
        let revealed = try review.revealAnswer(source, lease: lease, at: Support.now)
        let content = try WordNoteV3ContentService(container: container)
        try content.deleteReviewCard(source.card.id, expectedRevision: revealed.card.revision, at: Support.now)
        let result = try content.capture(.init(rawText: "QUICK"), at: Support.now)
        guard case .vocabulary = result.destination else { return XCTFail("Expected local lookup") }
        let payload = try V3SessionTestSupport.snapshot(container)
        let replacement = try XCTUnwrap(payload.cards.first)
        XCTAssertEqual(replacement.schedule.phase, .new)
        XCTAssertEqual(replacement.schedule.priorityRequestedAt, Support.now)
        XCTAssertEqual(replacement.schedule.buriedUntil, try ReviewStudyDay(containing: Support.now, timeZoneID: Support.zone).end)
        XCTAssertTrue(payload.content.content.reviewEvents.isEmpty)
        XCTAssertThrowsError(try review.startSession(scope: V3SessionTestSupport.scope(newCards: true), at: Support.now))
    }

    func testExposureAloneRequiresFormatFourAndSurvivesRepairEvidence() async throws {
        let container = try Support.container()
        let review = try WordNoteV3ReviewService(container: container)
        let (lease, source) = try V3SessionTestSupport.startPresented(review)
        _ = try review.revealAnswer(source, lease: lease, at: Support.now)
        var payload = try V3SessionTestSupport.snapshot(container)
        for index in payload.sessions.indices {
            payload.sessions[index].controls = nil
            payload.sessions[index].introductions = nil
        }
        var document = try JSONDecoder().decode(WordNoteSnapshotV3Document.self, from: WordNoteSnapshotV3Codec.encode(payload, kind: .manual))
        for version in 1...3 {
            document.formatVersion = version
            XCTAssertThrowsError(try WordNoteSnapshotReader.decode(JSONEncoder().encode(document)))
        }
        let directory = try V3TestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WordNoteV3RepairEvidenceVault(directoryURL: directory)
        let saved = try await vault.create(payload, generation: .init(id: UUID()), at: Support.now)
        let read = try await vault.read(id: saved.summary.id)
        XCTAssertEqual(read.payload, payload)
        let url = await vault.fileURL(saved.summary.id)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for version in 1...3 {
            object["evidenceFormatVersion"] = version
            try PrivateFileIO.write(JSONSerialization.data(withJSONObject: object), to: url)
            do { _ = try await vault.read(id: saved.summary.id); XCTFail("Downlabeling must fail") }
            catch { XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedFormat) }
        }
        payload.termHistories[0].reviewExposedUntil = .init(timeIntervalSince1970: .infinity)
        XCTAssertThrowsError(try payload.validate())
    }

    func testClockRollbackAndExistingLaterBurialCannotBypassExposure() throws {
        let container = try Support.container()
        let review = try WordNoteV3ReviewService(container: container)
        let (_, source) = try V3SessionTestSupport.startPresented(review)
        let sibling = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewCardModel>()).first)
        let later = Support.now.addingTimeInterval(172_800)
        sibling.buriedUntil = later
        try container.mainContext.save()
        let content = try WordNoteV3ContentService(container: container)
        let card = try content.enableReviewDirection(termID: source.term.id, expectedTermRevision: 0, mode: .chineseToEnglish,
            studyTimeZoneID: Support.zone, at: Support.now.addingTimeInterval(-86_400))
        XCTAssertEqual(card.schedule.buriedUntil, later)
    }

    func testReenablePreservesOwnAbilityAndDoesNotReviveOldSessionItem() throws {
        let container = try Support.container()
        let review = try WordNoteV3ReviewService(container: container)
        let (lease, _) = try V3SessionTestSupport.startPresented(review)
        _ = try V3SessionTestSupport.answer(review, lease: lease)
        var payload = try V3SessionTestSupport.snapshot(container)
        let card = payload.cards[0]
        let content = try WordNoteV3ContentService(container: container)
        try content.suspendReviewCard(card.id, expectedRevision: card.revision, at: Support.now)
        payload = try V3SessionTestSupport.snapshot(container)
        let resumed = try content.enableReviewDirection(termID: card.termID, expectedTermRevision: payload.content.termStates[0].revision,
            mode: card.mode, studyTimeZoneID: Support.zone, at: Support.now)
        XCTAssertEqual(resumed.id, card.id)
        XCTAssertEqual(resumed.schedule.phase, .review)
        XCTAssertEqual(resumed.schedule.masteryLevel, card.schedule.masteryLevel)
        XCTAssertEqual(resumed.schedule.lapseCount, card.schedule.lapseCount)
        XCTAssertEqual(resumed.schedule.introducedAt, card.schedule.introducedAt)
        XCTAssertEqual(try V3SessionTestSupport.snapshot(container).sessionItems, payload.sessionItems)
    }

    func testLegacySuspendedDirectionRemainsReviewInsteadOfInventingNewCardHistory() throws {
        let original = try V3TestSupport.payload()
        let container = try V3ReviewTestSupport.seeded(original)
        let content = try WordNoteV3ContentService(container: container)
        let card = original.cards[0]
        try content.suspendReviewCard(card.id, expectedRevision: card.revision, at: Support.now)
        let before = try WordNoteSnapshotV3Payload.capture(from: container.mainContext)
        let revision = try XCTUnwrap(before.content.termStates.first { $0.id == card.termID }).revision
        let resumed = try content.enableReviewDirection(termID: card.termID, expectedTermRevision: revision, mode: card.mode,
            studyTimeZoneID: Support.zone, at: Support.now)
        XCTAssertEqual(resumed.schedule.phase, .review)
        XCTAssertEqual(resumed.schedulerVersion, ReviewSchedulerVersion.legacy)
        XCTAssertEqual(resumed.schedule.introducedAt, card.schedule.introducedAt)
    }

    func testEnableFailureRollsBackWithoutMutatingSibling() throws {
        let container = try Support.container()
        let before = try V3SessionTestSupport.snapshot(container)
        let content = try WordNoteV3ContentService(container: container, beforeSave: { _ in throw V3ReviewTestSupport.Failure.save })
        XCTAssertThrowsError(try content.enableReviewDirection(termID: before.content.content.terms[0].id, expectedTermRevision: 0,
            mode: .chineseToEnglish, studyTimeZoneID: Support.zone, at: Support.now))
        XCTAssertEqual(try V3SessionTestSupport.snapshot(container), before)
    }
}
