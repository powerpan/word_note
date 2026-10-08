import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3SessionPresentationTests: XCTestCase {
    private typealias Support = V3SessionTestSupport

    func testFirstPresentationChargesAtomicallyAndRepeatedReadDoesNotChargeOrPresentAgain() throws {
        let container = try Support.container(count: 1, newCards: true)
        var saves = 0
        let service = try WordNoteV3ReviewService(container: container, beforeSave: { _ in saves += 1 })
        let started = try service.startSession(scope: Support.scope(newCards: true), at: Support.now)
        let lease = try service.acquireLease(sessionID: started.session.id, ownerID: UUID())
        let first = try XCTUnwrap(service.presentNextCard(lease: lease, expectedRevision: 0, at: Support.now))
        let after = try Support.snapshot(container)
        let second = try service.presentNextCard(lease: lease, expectedRevision: first.session.revision, at: Support.now.addingTimeInterval(100))
        XCTAssertEqual(first, second)
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(try Support.snapshot(container), after)
        XCTAssertEqual(first.card.schedule.introducedAt, Support.now)
        XCTAssertEqual(first.session.introductions?.count, 1)
        XCTAssertEqual(first.session.introductions?.first?.originalCardID, first.card.id)
        XCTAssertEqual(first.item.status, .presented)
        XCTAssertEqual(first.item.attemptCount, 0)
        XCTAssertTrue(after.eventStates.isEmpty)
        XCTAssertEqual(try service.newCardQuota(studyTimeZoneID: Support.zone, at: Support.now).used, 1)
        XCTAssertThrowsError(try service.previewFeedback(.good, lease: lease, at: Support.now))
    }

    func testPauseResumeReacquiresOwnershipAndRestoresFrontWithoutAnotherPresentation() throws {
        let container = try Support.container(count: 1, newCards: true)
        let service = try WordNoteV3ReviewService(container: container)
        let started = try service.startSession(scope: Support.scope(newCards: true), at: Support.now)
        let lease = try service.acquireLease(sessionID: started.session.id, ownerID: UUID())
        let shown = try XCTUnwrap(service.presentNextCard(lease: lease, expectedRevision: 0, at: Support.now))
        let revealed = try service.revealAnswer(shown, lease: lease, at: Support.now)
        let paused = try service.pauseSession(lease: lease, expectedRevision: revealed.session.revision, at: Support.now)
        XCTAssertEqual(paused.session.status, .paused)
        XCTAssertThrowsError(try service.previewFeedback(.good, lease: lease, at: Support.now))
        let reopened = try WordNoteV3ReviewService(container: container)
        let newLease = try reopened.acquireLease(sessionID: paused.session.id, ownerID: UUID())
        XCTAssertThrowsError(try reopened.presentNextCard(lease: newLease, expectedRevision: paused.session.revision, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .sessionPaused)
        }
        let resumed = try reopened.resumeSession(lease: newLease, expectedRevision: paused.session.revision, at: Support.now)
        let front = try XCTUnwrap(reopened.presentNextCard(lease: newLease, expectedRevision: resumed.session.revision, at: Support.now))
        XCTAssertEqual(front.card, revealed.card)
        XCTAssertEqual(front.item, revealed.item)
        XCTAssertEqual(front.session.introductions, revealed.session.introductions)
        XCTAssertThrowsError(try reopened.previewFeedback(.good, lease: newLease, at: Support.now))
        XCTAssertEqual(try reopened.resumableSession(), try reopened.reviewSession(started.session.id))
    }

    func testWaitingWakesAtExactMinuteBoundaryAndRepeatIsIdempotent() throws {
        let container = try Support.container(count: 1)
        let service = try WordNoteV3ReviewService(container: container)
        let session = try service.startSession(scope: Support.scope(), at: Support.now)
        let lease = try service.acquireLease(sessionID: session.session.id, ownerID: UUID())
        _ = try service.presentNextCard(lease: lease, expectedRevision: 0, at: Support.now)
        _ = try Support.answer(service, lease: lease, feedback: .again)
        let waiting = try service.reviewSession(session.session.id)
        let before = try Support.snapshot(container)
        XCTAssertEqual(waiting.session.status, .waiting)
        XCTAssertNil(try service.presentNextCard(lease: lease, expectedRevision: waiting.session.revision, at: Support.now.addingTimeInterval(599)))
        XCTAssertEqual(try Support.snapshot(container), before)
        let repeated = try XCTUnwrap(service.presentNextCard(lease: lease, expectedRevision: waiting.session.revision, at: Support.now.addingTimeInterval(600)))
        XCTAssertEqual(repeated.card.schedule.relearningRepeatCount, 1)
        XCTAssertEqual(repeated.item.attemptCount, 1)
        XCTAssertEqual(repeated.session.status, .active)
        XCTAssertEqual(try service.presentNextCard(lease: lease, expectedRevision: repeated.session.revision,
            at: Support.now.addingTimeInterval(601)), repeated)
        XCTAssertEqual(try Support.snapshot(container).eventStates.count, 1)
    }

    func testDueRelearningPrecedesPendingButDoesNotInterruptPresentedCard() throws {
        let container = try Support.container(count: 3)
        let service = try WordNoteV3ReviewService(container: container)
        let session = try service.startSession(scope: Support.scope(), at: Support.now)
        let lease = try service.acquireLease(sessionID: session.session.id, ownerID: UUID())
        let first = try XCTUnwrap(service.presentNextCard(lease: lease, expectedRevision: 0, at: Support.now))
        _ = try Support.answer(service, lease: lease, feedback: .again)
        let pending = try service.reviewSession(session.session.id)
        let second = try XCTUnwrap(service.presentNextCard(lease: lease, expectedRevision: pending.session.revision, at: Support.now.addingTimeInterval(1)))
        XCTAssertNotEqual(second.card.id, first.card.id)
        XCTAssertEqual(try service.presentNextCard(lease: lease, expectedRevision: second.session.revision,
            at: Support.now.addingTimeInterval(600)), second)
        _ = try Support.answer(service, lease: lease, at: Support.now.addingTimeInterval(600))
        let state = try service.reviewSession(session.session.id)
        let repeatCard = try XCTUnwrap(service.presentNextCard(lease: lease, expectedRevision: state.session.revision, at: Support.now.addingTimeInterval(600)))
        XCTAssertEqual(repeatCard.card.id, first.card.id)
        XCTAssertEqual(repeatCard.card.schedule.relearningRepeatCount, 1)
        XCTAssertEqual(try service.reviewSession(session.session.id).items.count, 3)
    }

    func testEndKeepsAllCardSchedulesAndDoesNotFabricateCompletionOrAnswers() throws {
        let container = try Support.container(count: 3)
        let service = try WordNoteV3ReviewService(container: container)
        let started = try service.startSession(scope: Support.scope(), at: Support.now)
        let lease = try service.acquireLease(sessionID: started.session.id, ownerID: UUID())
        let before = try Support.snapshot(container)
        let ended = try service.endSession(lease: lease, expectedRevision: 0, at: Support.now)
        XCTAssertEqual(ended.session.status, .ended)
        XCTAssertNil(ended.session.currentItemID)
        XCTAssertEqual(ended.items, started.items)
        XCTAssertEqual(try Support.snapshot(container).cards, before.cards)
        XCTAssertTrue(try Support.snapshot(container).eventStates.isEmpty)
        XCTAssertNil(try service.resumableSession())
        XCTAssertEqual(try service.startSession(id: started.session.id, scope: Support.scope(), at: Support.now), ended)
        XCTAssertNoThrow(try service.startSession(scope: Support.scope(), at: Support.now))
    }

    func testPresentationFailureRollsBackCardItemLedgerAndCursorAndCanRetry() throws {
        let container = try Support.container(count: 2, newCards: true)
        let start = try WordNoteV3ReviewService(container: container).startSession(scope: Support.scope(newCards: true), at: Support.now)
        var shouldFail = true
        let service = try WordNoteV3ReviewService(container: container, beforeSave: { _ in
            if shouldFail { throw V3ReviewTestSupport.Failure.save }
        })
        let lease = try service.acquireLease(sessionID: start.session.id, ownerID: UUID())
        let before = try Support.snapshot(container)
        XCTAssertThrowsError(try service.presentNextCard(lease: lease, expectedRevision: 0, at: Support.now))
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertFalse(container.mainContext.hasChanges)
        shouldFail = false
        XCTAssertNotNil(try service.presentNextCard(lease: lease, expectedRevision: 0, at: Support.now))
        XCTAssertEqual(try service.newCardQuota(studyTimeZoneID: Support.zone, at: Support.now).used, 1)
    }

    func testPauseAndEndFailureDoNotReleaseOwnershipOrChangeProgress() throws {
        for end in [false, true] {
            let container = try Support.container(count: 1)
            let start = try WordNoteV3ReviewService(container: container).startSession(scope: Support.scope(), at: Support.now)
            let service = try WordNoteV3ReviewService(container: container, beforeSave: { _ in throw V3ReviewTestSupport.Failure.save })
            let lease = try service.acquireLease(sessionID: start.session.id, ownerID: UUID())
            let before = try Support.snapshot(container)
            XCTAssertThrowsError(try end ? service.endSession(lease: lease, expectedRevision: 0, at: Support.now)
                : service.pauseSession(lease: lease, expectedRevision: 0, at: Support.now))
            XCTAssertEqual(try Support.snapshot(container), before)
            XCTAssertEqual(try service.acquireLease(sessionID: start.session.id, ownerID: lease.ownerID), lease)
            XCTAssertThrowsError(try WordNoteV3ReviewService(container: container).acquireLease(sessionID: start.session.id, ownerID: UUID()))
        }
    }

    func testStaleRevisionAndDirtyDraftDoNotGetCommittedBySessionOperations() throws {
        let container = try Support.container(count: 1)
        let service = try WordNoteV3ReviewService(container: container)
        let start = try service.startSession(scope: Support.scope(), at: Support.now)
        let lease = try service.acquireLease(sessionID: start.session.id, ownerID: UUID())
        let before = try Support.snapshot(container)
        XCTAssertThrowsError(try service.presentNextCard(lease: lease, expectedRevision: 4, at: Support.now))
        XCTAssertThrowsError(try service.pauseSession(lease: lease, expectedRevision: 4, at: Support.now))
        XCTAssertEqual(try Support.snapshot(container), before)
        let term = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()).first)
        term.chineseMeaning = "unsaved"
        XCTAssertThrowsError(try service.presentNextCard(lease: lease, expectedRevision: 0, at: Support.now))
        XCTAssertTrue(container.mainContext.hasChanges)
        XCTAssertEqual(term.chineseMeaning, "unsaved")
        container.mainContext.rollback()
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testPresentedCardAndQuotaSurviveFullBackupStagedRestoreAndDiskReopen() async throws {
        let container = try Support.container(count: 1, newCards: true)
        let service = try WordNoteV3ReviewService(container: container)
        let start = try service.startSession(scope: Support.scope(newCards: true), at: Support.now)
        let lease = try service.acquireLease(sessionID: start.session.id, ownerID: UUID())
        _ = try service.presentNextCard(lease: lease, expectedRevision: 0, at: Support.now)
        let saved = try Support.snapshot(container)
        let decoded = try WordNoteSnapshotV3Codec.decode(WordNoteSnapshotV3Codec.encode(saved, kind: .manual)).payload
        XCTAssertEqual(decoded, saved)
        let harness = V3RecoveryHarness(directory: try V3TestSupport.directory())
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        _ = try await harness.seed(.v3(decoded))
        let restored = try harness.store.open()
        let newService = try WordNoteV3ReviewService(container: restored.container)
        let state = try XCTUnwrap(newService.resumableSession())
        let newLease = try newService.acquireLease(sessionID: state.session.id, ownerID: UUID())
        let front = try XCTUnwrap(newService.presentNextCard(lease: newLease, expectedRevision: state.session.revision, at: Support.now.addingTimeInterval(100)))
        XCTAssertEqual(front.card.schedule.introducedAt, Support.now)
        XCTAssertEqual(try newService.newCardQuota(studyTimeZoneID: Support.zone, at: Support.now).used, 1)
        XCTAssertEqual(try harness.capture(restored), .v3(saved))
        XCTAssertThrowsError(try newService.previewFeedback(.good, lease: newLease, at: Support.now))
    }

    func testRestoreGateInvalidatesPendingPresentationAndRequiresNewLease() throws {
        let container = try Support.container(count: 1, newCards: true)
        let service = try WordNoteV3ReviewService(container: container)
        let start = try service.startSession(scope: Support.scope(newCards: true), at: Support.now)
        let old = try service.acquireLease(sessionID: start.session.id, ownerID: UUID())
        let ticket = try WordNoteWriteGate.beginRestore(container.mainContext)
        XCTAssertThrowsError(try service.presentNextCard(lease: old, expectedRevision: 0, at: Support.now))
        try WordNoteWriteGate.endRestore(container.mainContext, ticket: ticket)
        XCTAssertThrowsError(try service.presentNextCard(lease: old, expectedRevision: 0, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteWriteError, .expiredOperation)
        }
        XCTAssertEqual(try service.newCardQuota(studyTimeZoneID: Support.zone, at: Support.now).used, 0)
        let fresh = try service.acquireLease(sessionID: start.session.id, ownerID: UUID())
        XCTAssertNotNil(try service.presentNextCard(lease: fresh, expectedRevision: 0, at: Support.now))
    }

    func testDeletingPendingCardPreservesFixedCountAndDoesNotReplaceItWithAnother() throws {
        let container = try Support.container(count: 7)
        let service = try WordNoteV3ReviewService(container: container)
        let start = try service.startSession(scope: Support.scope(), targetCardCount: 5, at: Support.now)
        let cardID = try XCTUnwrap(start.items[0].cardID)
        try WordNoteV3ContentService(container: container).deleteReviewCard(cardID, expectedRevision: 0, at: Support.now)
        let interrupted = try service.reviewSession(start.session.id)
        XCTAssertEqual(interrupted.session.status, .paused)
        XCTAssertEqual(interrupted.items.map(\.originalCardID), start.items.map(\.originalCardID))
        XCTAssertEqual(interrupted.items[0].status, .unavailable)
        let lease = try service.acquireLease(sessionID: start.session.id, ownerID: UUID())
        let resumed = try service.resumeSession(lease: lease, expectedRevision: interrupted.session.revision, at: Support.now)
        let shown = try XCTUnwrap(service.presentNextCard(lease: lease, expectedRevision: resumed.session.revision, at: Support.now))
        XCTAssertEqual(shown.card.id, start.items[1].cardID)
        XCTAssertEqual(try service.reviewSession(start.session.id).items.count, 5)
    }

    func testFullRelearningCycleStopsAtTwoRepeatsAndResetsOnlyOnNextDaysPresentation() throws {
        let container = try Support.container(count: 1)
        let service = try WordNoteV3ReviewService(container: container)
        let start = try service.startSession(scope: Support.scope(), at: Support.now)
        let lease = try service.acquireLease(sessionID: start.session.id, ownerID: UUID())
        for repeatCount in 0...2 {
            let time = Support.now.addingTimeInterval(Double(repeatCount) * 600)
            let session = try service.reviewSession(start.session.id)
            let shown = try XCTUnwrap(service.presentNextCard(lease: lease, expectedRevision: session.session.revision, at: time))
            XCTAssertEqual(shown.card.schedule.relearningRepeatCount, repeatCount)
            _ = try Support.answer(service, lease: lease, feedback: .again, at: time)
        }
        let completed = try service.reviewSession(start.session.id)
        XCTAssertEqual(completed.session.status, .completed)
        XCTAssertEqual(completed.items[0].status, .postponed)
        XCTAssertEqual(completed.items[0].attemptCount, 3)
        XCTAssertThrowsError(try service.startSession(scope: Support.scope(), at: Support.now.addingTimeInterval(1201)))
        let tomorrow = try ReviewStudyDay(containing: Support.now, timeZoneID: Support.zone).end
        let next = try service.startSession(scope: Support.scope(), at: tomorrow)
        let owner = try service.acquireLease(sessionID: next.session.id, ownerID: UUID())
        let shown = try XCTUnwrap(service.presentNextCard(lease: owner, expectedRevision: 0, at: tomorrow))
        XCTAssertEqual(shown.card.schedule.relearningRepeatCount, 0)
        XCTAssertEqual(shown.card.schedule.lapseCount, 3)
    }

    func testQuotaIsRecheckedAtPresentationAndCounterOverflowCannotLeavePartialCharge() throws {
        for fault in ["quota", "card", "session"] {
            let container = try Support.container(count: 1, newCards: true)
            let service = try WordNoteV3ReviewService(container: container)
            let start = try service.startSession(scope: Support.scope(newCards: true), at: Support.now)
            let session = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewSessionModel>()).first)
            let card = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewCardModel>()).first)
            if fault == "quota" { session.newCardLimitSnapshot = 0 }
            if fault == "card" { card.revision = 1_000_000_000 }
            if fault == "session" { session.revision = 1_000_000_000 }
            try container.mainContext.save()
            let before = try Support.snapshot(container)
            let lease = try service.acquireLease(sessionID: start.session.id, ownerID: UUID())
            XCTAssertThrowsError(try service.presentNextCard(lease: lease, expectedRevision: session.revision, at: Support.now))
            XCTAssertEqual(try Support.snapshot(container), before)
            XCTAssertFalse(container.mainContext.hasChanges)
        }
    }
}
