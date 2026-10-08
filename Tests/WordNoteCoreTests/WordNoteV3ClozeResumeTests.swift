import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3ClozeResumeTests: XCTestCase {
    private typealias Support = V3QuestionTestSupport

    func testUnintroducedClozeResumesSameCardAfterSnapshotRestoreAndActiveRetryIsReadOnly() throws {
        let container = try Support.container()
        let content = try WordNoteV3ContentService(container: container)
        let card = try Support.create(content, container: container)
        try content.suspendReviewCard(card.id, expectedRevision: card.revision, at: Support.now)
        let suspended = try V3SessionTestSupport.snapshot(container)
        let restored = try V3ReviewTestSupport.seeded(WordNoteSnapshotV3Codec.decode(
            WordNoteSnapshotV3Codec.encode(suspended, kind: .manual)).payload)
        var saves = 0
        let service = try WordNoteV3ContentService(container: restored, beforeSave: { _ in saves += 1 })
        let result = try service.resumeClozeCard(card.id, expectedRevision: card.revision + 1,
            studyTimeZoneID: Support.zone, at: Support.now)
        XCTAssertEqual(result.id, card.id)
        XCTAssertEqual(result.clozeTarget, card.clozeTarget)
        XCTAssertEqual(result.contentScopeKey, card.contentScopeKey)
        XCTAssertEqual(result.schedule, card.schedule)
        let after = try V3SessionTestSupport.snapshot(restored)
        XCTAssertEqual(after.cards.filter { $0.id != card.id }, suspended.cards.filter { $0.id != card.id })
        XCTAssertEqual(after.content.content.terms, suspended.content.content.terms)
        XCTAssertEqual(after.eventStates, suspended.eventStates)
        XCTAssertEqual(try service.resumeClozeCard(card.id, expectedRevision: result.revision,
            studyTimeZoneID: Support.zone, at: Support.now), result)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try V3SessionTestSupport.snapshot(restored), after)
    }

    func testLearnedClozeKeepsAbilityQuotaExposureAndInvalidatedSessionItems() throws {
        let container = try Support.container()
        let content = try WordNoteV3ContentService(container: container)
        let card = try Support.create(content, container: container)
        let review = try WordNoteV3ReviewService(container: container)
        let session = try review.startSession(scope: V3SessionTestSupport.scope(newCards: true, mode: .contextCloze), at: Support.now)
        let lease = try review.acquireLease(sessionID: session.session.id, ownerID: UUID())
        _ = try review.presentNextCard(lease: lease, expectedRevision: session.session.revision, at: Support.now)
        _ = try V3SessionTestSupport.answer(review, lease: lease)
        let learned = try XCTUnwrap(V3SessionTestSupport.snapshot(container).cards.first { $0.id == card.id })
        let later = Support.now.addingTimeInterval(30)
        try content.suspendReviewCard(card.id, expectedRevision: learned.revision, at: later)
        let before = try V3SessionTestSupport.snapshot(container)
        let result = try content.resumeClozeCard(card.id, expectedRevision: learned.revision + 1,
            studyTimeZoneID: Support.zone, at: Support.now.addingTimeInterval(-60))
        var expected = learned.schedule
        expected.phase = .review
        expected.nextReviewAt = later
        expected.buriedUntil = try ReviewStudyDay(containing: Support.now, timeZoneID: Support.zone).end
        XCTAssertEqual(result.schedule, expected)
        XCTAssertEqual(result.updatedAt, later)
        let after = try V3SessionTestSupport.snapshot(container)
        XCTAssertEqual(after.sessions, before.sessions)
        XCTAssertEqual(after.sessionItems, before.sessionItems)
        XCTAssertEqual(after.eventStates, before.eventStates)
        XCTAssertEqual(after.content.content.reviewEvents, before.content.content.reviewEvents)
        XCTAssertEqual(try review.newCardQuota(studyTimeZoneID: Support.zone, at: Support.now).used, 1)
    }

    func testDeletedOrEditedOccurrenceCannotBeResumed() throws {
        for delete in [true, false] {
            let container = try Support.container()
            let service = try WordNoteV3ContentService(container: container)
            let card = try Support.create(service, container: container)
            let initial = try V3SessionTestSupport.snapshot(container)
            if delete {
                try service.deleteOccurrence(initial.content.occurrences[0].id,
                    expectedTermRevision: initial.content.termStates[0].revision, at: Support.now)
            } else {
                try service.reviseOccurrenceText(initial.content.occurrences[0],
                    expectedTermRevision: initial.content.termStates[0].revision, rawText: "A different quick source.", at: Support.now)
            }
            let before = try V3SessionTestSupport.snapshot(container)
            let revision = try XCTUnwrap(before.cards.first { $0.id == card.id }).revision
            XCTAssertThrowsError(try service.resumeClozeCard(card.id, expectedRevision: revision,
                studyTimeZoneID: Support.zone, at: Support.now))
            XCTAssertEqual(try V3SessionTestSupport.snapshot(container), before)
        }
    }

    func testDeletingInboxRecordDoesNotDestroyAValidSavedClozeTarget() throws {
        let container = try Support.container()
        let service = try WordNoteV3ContentService(container: container)
        let card = try Support.create(service, container: container)
        let record = try V3SessionTestSupport.snapshot(container).content.content.inputRecords[0]
        try service.deleteInputRecord(record.id, expectedRevision: 0, at: Support.now)
        try service.suspendReviewCard(card.id, expectedRevision: card.revision, at: Support.now)
        let result = try service.resumeClozeCard(card.id, expectedRevision: card.revision + 1,
            studyTimeZoneID: Support.zone, at: Support.now)
        XCTAssertEqual(result.clozeTarget, card.clozeTarget)
        XCTAssertEqual(result.schedule.phase, .new)
        let payload = try V3SessionTestSupport.snapshot(container)
        XCTAssertNoThrow(try ReviewQuestionContent.front(card: result, term: payload.content.content.terms[0],
            occurrence: payload.content.occurrences[0]))
    }

    func testResumeSaveFailureRollsBackAndSameRevisionCanRetry() throws {
        let container = try Support.container()
        let content = try WordNoteV3ContentService(container: container)
        let card = try Support.create(content, container: container)
        try content.suspendReviewCard(card.id, expectedRevision: card.revision, at: Support.now)
        let before = try V3SessionTestSupport.snapshot(container)
        var fail = true
        let service = try WordNoteV3ContentService(container: container, beforeSave: { _ in
            if fail { throw V3ReviewTestSupport.Failure.save }
        })
        XCTAssertThrowsError(try service.resumeClozeCard(card.id, expectedRevision: card.revision + 1,
            studyTimeZoneID: Support.zone, at: Support.now))
        XCTAssertEqual(try V3SessionTestSupport.snapshot(container), before)
        XCTAssertFalse(container.mainContext.hasChanges)
        fail = false
        XCTAssertNoThrow(try service.resumeClozeCard(card.id, expectedRevision: card.revision + 1,
            studyTimeZoneID: Support.zone, at: Support.now))
    }

    func testMissingCardStaleRevisionWrongModeInvalidClockAndZoneDoNotWrite() throws {
        let container = try Support.container()
        let service = try WordNoteV3ContentService(container: container)
        let card = try Support.create(service, container: container)
        try service.suspendReviewCard(card.id, expectedRevision: card.revision, at: Support.now)
        let before = try V3SessionTestSupport.snapshot(container)
        let whole = try XCTUnwrap(before.cards.first { $0.mode == .englishToChinese })
        let cases: [(UUID, Int, String, Date)] = [
            (UUID(), 0, Support.zone, Support.now),
            (card.id, card.revision, Support.zone, Support.now),
            (whole.id, whole.revision, Support.zone, Support.now),
            (card.id, card.revision + 1, "unknown-zone", Support.now),
            (card.id, card.revision + 1, Support.zone, .init(timeIntervalSince1970: .infinity))
        ]
        for (id, revision, zone, date) in cases {
            XCTAssertThrowsError(try service.resumeClozeCard(id, expectedRevision: revision, studyTimeZoneID: zone, at: date))
            XCTAssertEqual(try V3SessionTestSupport.snapshot(container), before)
        }
    }
}
