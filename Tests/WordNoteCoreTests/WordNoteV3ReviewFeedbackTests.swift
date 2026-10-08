import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3ReviewFeedbackTests: XCTestCase {
    private typealias Support = V3ReviewTestSupport

    func testEveryFeedbackAtomicallyWritesVersionedEventCardAndProgressWithoutTermMutation() throws {
        for feedback in ReviewFeedback.allCases {
            let original = try Support.payload()
            let container = try Support.seeded(original)
            let service = try WordNoteV3ReviewService(container: container)
            let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
            let before = try Support.snapshot(container, original: original)
            let preview = try service.previewFeedback(feedback, lease: lease, at: Support.now)
            XCTAssertEqual(try Support.snapshot(container, original: original), before)
            let actionID = UUID(), answerTime = Support.now.addingTimeInterval(15)
            let expected = try ReviewCardScheduler().feedback(feedback, for: preview.source.card.schedule, at: answerTime,
                studyTimeZoneID: preview.source.session.scope.studyTimeZoneID, lastInteractionAt: preview.source.card.updatedAt)
            let receipt = try service.recordFeedback(preview, actionID: actionID, lease: lease, at: answerTime)
            let after = try Support.snapshot(container, original: original)
            XCTAssertFalse(receipt.isReplay)
            XCTAssertEqual(receipt.after, expected.after)
            XCTAssertEqual(receipt.reviewedAt, answerTime)
            XCTAssertEqual(receipt.disposition, expected.disposition)
            XCTAssertEqual(after.content.content.terms, before.content.content.terms)
            XCTAssertEqual(after.content.termStates, before.content.termStates)
            XCTAssertEqual(after.termHistories, before.termHistories)
            XCTAssertEqual(after.content.lookupEvents, before.content.lookupEvents)
            let card = try XCTUnwrap(after.cards.first { $0.id == receipt.originalCardID })
            XCTAssertEqual(card.schedule, expected.after)
            XCTAssertEqual(card.revision, preview.source.card.revision + 1)
            XCTAssertEqual(card.updatedAt, answerTime)
            XCTAssertEqual(card.schedulerVersion, ReviewSchedulerVersion.current)
            let event = try XCTUnwrap(after.content.content.reviewEvents.first { $0.id == receipt.eventID })
            let state = try XCTUnwrap(after.eventStates.first { $0.id == receipt.eventID })
            XCTAssertEqual(event.feedbackRaw, feedback.rawValue)
            XCTAssertEqual(event.reviewedAt, answerTime)
            XCTAssertEqual(state.feedbackSemanticsVersion, 2)
            XCTAssertEqual(state.schedulerVersion, ReviewSchedulerVersion.current)
            XCTAssertEqual(state.actionID, actionID)
            XCTAssertEqual(state.beforeSchedule, expected.before)
            XCTAssertEqual(state.afterSchedule, expected.after)
            XCTAssertEqual(state.studyDayKey, expected.clock.studyDayKey)
            XCTAssertEqual(state.studyTimeZoneID, "Asia/Hong_Kong")
            XCTAssertEqual(after.content.content.reviewEvents.count, before.content.content.reviewEvents.count + 1)
            let item = after.sessionItems[0]
            XCTAssertEqual(item.attemptCount, 1)
            XCTAssertEqual(item.lastActionID, actionID)
            XCTAssertEqual(item.status, feedback == .again ? .waiting : .completed)
            XCTAssertEqual(item.completionOutcome, feedback == .again ? nil : .reviewed)
            XCTAssertEqual(item.availableAt, feedback == .again ? expected.after.nextReviewAt : nil)
            XCTAssertEqual(after.sessions[0].status, feedback == .again ? .waiting : .completed)
            XCTAssertNil(after.sessions[0].currentItemID)
            XCTAssertEqual(after.sessions[0].revision, before.sessions[0].revision + 1)
        }
    }

    func testRelearningHardWaitsWithoutFailureAndExhaustedAgainHardPostpone() throws {
        for repeats in [1, 2] {
            for feedback in [ReviewFeedback.again, .hard] {
                let original = try Support.payload(relearningRepeat: repeats)
                let container = try Support.seeded(original)
                let service = try WordNoteV3ReviewService(container: container)
                let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
                let preview = try service.previewFeedback(feedback, lease: lease, at: Support.now)
                let receipt = try service.recordFeedback(preview, actionID: UUID(), lease: lease, at: Support.now)
                let after = try Support.snapshot(container, original: original)
                XCTAssertEqual(receipt.after.lapseCount, receipt.before.lapseCount + (feedback == .again ? 1 : 0))
                XCTAssertEqual(receipt.after.relearningRepeatCount, repeats)
                XCTAssertEqual(receipt.disposition, repeats == 2 ? .relearningLimitReached : .relearning)
                XCTAssertEqual(after.sessionItems[0].status, repeats == 2 ? .postponed : .waiting)
                XCTAssertEqual(after.sessionItems[0].completionOutcome, repeats == 2 ? .postponed : nil)
                XCTAssertEqual(after.sessionItems[0].attemptCount, 2)
                XCTAssertEqual(after.sessions[0].status, repeats == 2 ? .completed : .waiting)
            }
        }
    }

    func testCursorAdvancesInsideFixedSetWithoutPresentingOrIntroducingNextCard() throws {
        let original = try Support.payload(pending: true)
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        let before = try Support.snapshot(container, original: original)
        let next = try XCTUnwrap(before.sessionItems.first { $0.status == .pending })
        let preview = try service.previewFeedback(.again, lease: lease, at: Support.now)
        _ = try service.recordFeedback(preview, actionID: UUID(), lease: lease, at: Support.now)
        let after = try Support.snapshot(container, original: original)
        XCTAssertEqual(after.sessionItems.count, before.sessionItems.count)
        XCTAssertEqual(after.sessions[0].scope, before.sessions[0].scope)
        XCTAssertEqual(after.sessions[0].currentItemID, next.id)
        XCTAssertEqual(after.sessions[0].status, .active)
        XCTAssertEqual(after.sessionItems.first { $0.id == next.id }, next)
        XCTAssertEqual(after.cards.first { $0.id == next.cardID }, before.cards.first { $0.id == next.cardID })
        XCTAssertThrowsError(try service.previewFeedback(.good, lease: lease, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .noActivePresentedItem)
        }
    }

    func testSameActionReplayAcrossServicesDoesNotWriteOrMoveProgressAgain() throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        var saves = 0
        let service = try WordNoteV3ReviewService(container: container, beforeSave: { _ in saves += 1 })
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        let preview = try service.previewFeedback(.good, lease: lease, at: Support.now)
        let actionID = UUID()
        let first = try service.recordFeedback(preview, actionID: actionID, lease: lease, at: Support.now)
        let saved = try Support.snapshot(container, original: original)
        let replay = try WordNoteV3ReviewService(container: container).recordFeedback(preview, actionID: actionID, lease: lease, at: Support.now.addingTimeInterval(900))
        XCTAssertTrue(replay.isReplay)
        XCTAssertEqual(first.eventID, replay.eventID)
        XCTAssertEqual(first.after, replay.after)
        XCTAssertEqual(replay, try service.feedbackReceipt(actionID: actionID))
        XCTAssertEqual(try Support.snapshot(container, original: original), saved)
        XCTAssertEqual(saves, 2)
        XCTAssertNil(try service.feedbackReceipt(actionID: UUID()))
    }

    func testSameActionDifferentFeedbackOrBeforeStateIsAConflict() throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        let good = try service.previewFeedback(.good, lease: lease, at: Support.now)
        let easy = try service.previewFeedback(.easy, lease: lease, at: Support.now)
        let actionID = UUID()
        _ = try service.recordFeedback(good, actionID: actionID, lease: lease, at: Support.now)
        let saved = try Support.snapshot(container, original: original)
        XCTAssertThrowsError(try service.recordFeedback(easy, actionID: actionID, lease: lease, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .actionConflict)
        }
        var changedCard = good.source.card
        changedCard.schedule.priorityRequestedAt = Support.now
        let changedSource = WordNoteV3ReviewAnswerSnapshot(session: good.source.session, item: good.source.item,
            card: changedCard, term: good.source.term, termState: good.source.termState)
        let changed = WordNoteV3FeedbackPreview(source: changedSource, plan: good.plan, leaseID: lease.id)
        XCTAssertThrowsError(try service.recordFeedback(changed, actionID: actionID, lease: lease, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .actionConflict)
        }
        XCTAssertEqual(try Support.snapshot(container, original: original), saved)
    }

    func testSecondClickWithDifferentActionIDCannotScoreTheSamePresentationTwice() throws {
        for feedback in [ReviewFeedback.again, .good] {
            let original = try Support.payload()
            let container = try Support.seeded(original)
            let service = try WordNoteV3ReviewService(container: container)
            let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
            let preview = try service.previewFeedback(feedback, lease: lease, at: Support.now)
            _ = try service.recordFeedback(preview, actionID: UUID(), lease: lease, at: Support.now)
            let saved = try Support.snapshot(container, original: original)
            XCTAssertThrowsError(try service.recordFeedback(preview, actionID: UUID(), lease: lease, at: Support.now))
            XCTAssertEqual(try Support.snapshot(container, original: original), saved)
        }
    }

    func testOldActionReplayCannotClearANewCardsRevealedAnswer() throws {
        let original = try Support.payload(pending: true)
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        let preview = try service.previewFeedback(.good, lease: lease, at: Support.now)
        let actionID = UUID()
        _ = try service.recordFeedback(preview, actionID: actionID, lease: lease, at: Support.now)
        let session = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewSessionModel>()).first)
        let item = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewSessionItemModel>()).first { $0.id == session.currentItemID })
        let card = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewCardModel>()).first { $0.id == item.cardID })
        let nextTime = Support.now.addingTimeInterval(1)
        try ReviewCardScheduler().presentation(for: ReviewCardSchedule(card), at: nextTime,
            studyTimeZoneID: "Asia/Hong_Kong", lastInteractionAt: card.updatedAt).after.apply(to: card)
        card.revision += 1
        card.updatedAt = nextTime
        item.statusRaw = "presented"
        item.updatedAt = nextTime
        session.revision += 1
        session.updatedAt = nextTime
        try container.mainContext.save()
        _ = try service.revealAnswer(service.currentAnswerSnapshot(sessionID: session.id), lease: lease, at: nextTime)
        let before = try Support.snapshot(container, original: original)
        XCTAssertTrue(try service.recordFeedback(preview, actionID: actionID, lease: lease, at: nextTime).isReplay)
        XCTAssertEqual(try Support.snapshot(container, original: original), before)
        XCTAssertNoThrow(try service.previewFeedback(.good, lease: lease, at: nextTime))
    }

    func testCrossMidnightAnswerRefreshPreservesPresentationBucketAndActualEventDay() throws {
        let original = try Support.payload(relearningRepeat: 2)
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let beforeMidnight = try ReviewCardTestSupport.date("2026-09-21T15:59:00Z")
        let afterMidnight = try ReviewCardTestSupport.date("2026-09-21T16:01:00Z")
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id, at: beforeMidnight)
        let old = try service.previewFeedback(.again, lease: lease, at: beforeMidnight)
        let saved = try Support.snapshot(container, original: original)
        XCTAssertThrowsError(try service.recordFeedback(old, actionID: UUID(), lease: lease, at: afterMidnight)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .stalePreview)
        }
        XCTAssertEqual(try Support.snapshot(container, original: original), saved)
        let fresh = try service.previewFeedback(.again, lease: lease, at: afterMidnight)
        let receipt = try service.recordFeedback(fresh, actionID: UUID(), lease: lease, at: afterMidnight)
        XCTAssertEqual(receipt.after.relearningDayKey, "2026-09-21")
        XCTAssertEqual(receipt.after.relearningRepeatCount, 2)
        XCTAssertEqual(receipt.after.nextReviewAt, afterMidnight.addingTimeInterval(600))
        XCTAssertEqual(receipt.disposition, .relearning)
        let result = try Support.snapshot(container, original: original)
        XCTAssertEqual(result.eventStates.first { $0.id == receipt.eventID }?.studyDayKey, "2026-09-22")
        XCTAssertEqual(result.sessionItems[0].status, .waiting)
    }

    func testDeletedTermActionCannotRecreateAnEventOrCard() throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        let preview = try service.previewFeedback(.good, lease: lease, at: Support.now)
        let actionID = UUID()
        _ = try service.recordFeedback(preview, actionID: actionID, lease: lease, at: Support.now)
        try WordNoteV3ContentService(container: container).deleteTerm(preview.source.term.id,
            expectedRevision: preview.source.termState.revision, at: Support.now)
        let deleted = try Support.snapshot(container, original: original)
        XCTAssertNil(try service.feedbackReceipt(actionID: actionID))
        XCTAssertThrowsError(try service.recordFeedback(preview, actionID: actionID, lease: lease, at: Support.now))
        XCTAssertEqual(try Support.snapshot(container, original: original), deleted)
    }

    func testReplaySurvivesFullBackupRestoreAndActualDiskReopenWithoutNewLease() async throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        let preview = try service.previewFeedback(.good, lease: lease, at: Support.now)
        let actionID = UUID()
        let first = try service.recordFeedback(preview, actionID: actionID, lease: lease, at: Support.now)
        let saved = try Support.snapshot(container, original: original)
        let decoded = try WordNoteSnapshotV3Codec.decode(WordNoteSnapshotV3Codec.encode(saved, kind: .manual)).payload
        let h = V3RecoveryHarness(directory: try V3TestSupport.directory())
        defer { try? FileManager.default.removeItem(at: h.directory) }
        _ = try await h.seed(.v3(decoded))
        let reopened = try h.store.open()
        let restored = try WordNoteV3ReviewService(container: reopened.container)
        let replay = try restored.recordFeedback(preview, actionID: actionID, lease: lease, at: Support.now.addingTimeInterval(1200))
        XCTAssertTrue(replay.isReplay)
        XCTAssertEqual(replay.eventID, first.eventID)
        XCTAssertEqual(try restored.feedbackReceipt(actionID: actionID), replay)
        XCTAssertEqual(try h.capture(reopened), .v3(saved))
    }

    func testDeletedCardReplayReturnsOriginalIdentityWithoutResurrectingCard() throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        let preview = try service.previewFeedback(.good, lease: lease, at: Support.now)
        let actionID = UUID()
        let first = try service.recordFeedback(preview, actionID: actionID, lease: lease, at: Support.now)
        let card = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewCardModel>()).first { $0.id == first.originalCardID })
        try WordNoteV3ContentService(container: container).deleteReviewCard(card.id, expectedRevision: card.revision, at: Support.now)
        let deleted = try Support.snapshot(container, original: original)
        let replay = try service.recordFeedback(preview, actionID: actionID, lease: lease, at: Support.now)
        XCTAssertEqual(replay.originalCardID, first.originalCardID)
        XCTAssertEqual(replay.eventID, first.eventID)
        XCTAssertEqual(try Support.snapshot(container, original: original), deleted)
    }

    func testInvalidatedEventIsNotReplayedAsSuccess() throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        let preview = try service.previewFeedback(.good, lease: lease, at: Support.now)
        let actionID = UUID()
        let receipt = try service.recordFeedback(preview, actionID: actionID, lease: lease, at: Support.now)
        let event = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewEventModel>()).first { $0.id == receipt.eventID })
        event.invalidatedAt = Support.now
        try container.mainContext.save()
        let before = try Support.snapshot(container, original: original)
        XCTAssertThrowsError(try service.recordFeedback(preview, actionID: actionID, lease: lease, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .invalidatedAction)
        }
        XCTAssertEqual(try Support.snapshot(container, original: original), before)
    }

    func testClockRollbackKeepsObservedEventTimeAndNondecreasingInteractionTime() throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        let observed = Support.now.addingTimeInterval(-30)
        let preview = try service.previewFeedback(.again, lease: lease, at: observed)
        let receipt = try service.recordFeedback(preview, actionID: UUID(), lease: lease, at: observed)
        XCTAssertEqual(receipt.clockAnomaly, .movedBackward)
        XCTAssertEqual(receipt.reviewedAt, observed)
        XCTAssertEqual(receipt.after.lastReviewedAt, observed)
        XCTAssertEqual(receipt.after.nextReviewAt, Support.now.addingTimeInterval(600))
        let saved = try Support.snapshot(container, original: original)
        XCTAssertEqual(saved.cards.first { $0.id == receipt.originalCardID }?.updatedAt, Support.now)
    }

    func testPreviewAtPreviousDayOrLaterClockMustRefreshWithoutWriting() throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        let preview = try service.previewFeedback(.good, lease: lease, at: Support.now)
        let saved = try Support.snapshot(container, original: original)
        for date in [Support.now.addingTimeInterval(-1), Support.now.addingTimeInterval(86_400)] {
            XCTAssertThrowsError(try service.recordFeedback(preview, actionID: UUID(), lease: lease, at: date)) {
                XCTAssertEqual($0 as? WordNoteV3ReviewError, .stalePreview)
            }
            XCTAssertEqual(try Support.snapshot(container, original: original), saved)
        }
    }

    func testTamperedPreviewCannotSupplyItsOwnSchedule() throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        let preview = try service.previewFeedback(.good, lease: lease, at: Support.now)
        var fakeAfter = preview.plan.after
        fakeAfter.lapseCount += 10
        let fakePlan = ReviewCardFeedbackPlan(feedback: .good, before: preview.plan.before, after: fakeAfter,
            clock: preview.plan.clock, delay: preview.plan.delay, disposition: preview.plan.disposition)
        let fake = WordNoteV3FeedbackPreview(source: preview.source, plan: fakePlan, leaseID: preview.leaseID)
        let before = try Support.snapshot(container, original: original)
        XCTAssertThrowsError(try service.recordFeedback(fake, actionID: UUID(), lease: lease, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .invalidPreview)
        }
        XCTAssertEqual(try Support.snapshot(container, original: original), before)
    }
}
