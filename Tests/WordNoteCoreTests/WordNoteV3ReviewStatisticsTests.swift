import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3ReviewStatisticsTests: XCTestCase {
    private typealias Support = V3SessionTestSupport

    func testZeroSamplesAndLegacyHistoryNeverProduceInventedRecall() throws {
        let payload = try V3TestSupport.payload()
        let stats = try ReviewStatisticsBuilder(payload: payload).overview(studyTimeZoneID: Support.zone, at: Support.now)
        XCTAssertEqual(stats.lifetime.answerCount, 0)
        XCTAssertEqual(stats.today.firstRecall.samples, 0)
        XCTAssertNil(stats.today.firstRecall.ratio)
        XCTAssertFalse(stats.today.hasEstimatedOrder)
    }

    func testRelearningAttemptsAreSeparateFromDistinctCardsAndFirstRecall() throws {
        let container = try Support.container(count: 1)
        let service = try WordNoteV3ReviewService(container: container)
        let (lease, _) = try Support.startPresented(service)
        for (index, feedback) in [ReviewFeedback.again, .hard, .good].enumerated() {
            let date = Support.now.addingTimeInterval(Double(index) * 600)
            _ = try Support.show(service, lease: lease, at: date)
            _ = try Support.answer(service, lease: lease, feedback: feedback, at: date)
        }
        let before = try Support.snapshot(container)
        let stats = try service.statistics(studyTimeZoneID: Support.zone, at: Support.now.addingTimeInterval(1200))
        XCTAssertEqual(stats.today.answerCount, 3)
        XCTAssertEqual(stats.today.answeredCardCount, 1)
        XCTAssertEqual(stats.today.completedCardCount, 1)
        XCTAssertEqual(stats.today.failureCount, 1)
        XCTAssertEqual(stats.today.firstRecall, .init(successes: 0, samples: 1))
        XCTAssertFalse(stats.today.hasEstimatedOrder)
        XCTAssertEqual(before.eventStates.compactMap(\.recordedOrder).sorted(), [1, 2, 3])
        let session = try service.sessionStatistics(lease.sessionID)
        XCTAssertEqual(session.totalItems, 1)
        XCTAssertEqual(session.reviewed, 1)
        XCTAssertEqual(session.processedRatio, 1)
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testHardCountsAsSuccessfulFirstRecallButLaterIsOnlyProcessed() throws {
        let container = try Support.container(count: 2)
        let service = try WordNoteV3ReviewService(container: container)
        let (lease, _) = try Support.startPresented(service)
        _ = try Support.answer(service, lease: lease, feedback: .hard)
        let next = try Support.show(service, lease: lease)
        _ = try service.later(next, actionID: UUID(), lease: lease, at: Support.now)
        let stats = try service.sessionStatistics(lease.sessionID)
        XCTAssertEqual(stats.totalItems, 2)
        XCTAssertEqual(stats.processedItems, 2)
        XCTAssertEqual(stats.reviewed, 1)
        XCTAssertEqual(stats.manualLater, 1)
        XCTAssertEqual(stats.answers.completedCardCount, 1)
        XCTAssertEqual(stats.answers.firstRecall, .init(successes: 1, samples: 1))
        XCTAssertEqual(stats.answers.failureCount, 0)
    }

    func testRelearningCapAndManualLaterNeverInflateSuccessfulCompletion() throws {
        for lastFeedback in [ReviewFeedback.again, .hard] {
            let container = try Support.container(count: 2)
            let service = try WordNoteV3ReviewService(container: container)
            let (lease, _) = try Support.startPresented(service)
            _ = try Support.answer(service, lease: lease, feedback: .again)
            let other = try Support.show(service, lease: lease)
            _ = try service.later(other, actionID: UUID(), lease: lease, at: Support.now)
            for repeatNumber in 1...2 {
                let date = Support.now.addingTimeInterval(Double(repeatNumber) * 600)
                _ = try Support.show(service, lease: lease, at: date)
                _ = try Support.answer(service, lease: lease, feedback: repeatNumber == 2 ? lastFeedback : .again, at: date)
            }
            let result = try service.sessionStatistics(lease.sessionID)
            XCTAssertEqual(result.processedItems, 2)
            XCTAssertEqual(result.manualLater, 1)
            XCTAssertEqual(result.relearningLimit, 1)
            XCTAssertEqual(result.reviewed, 0)
            XCTAssertEqual(result.answers.answerCount, 3)
            XCTAssertEqual(result.answers.completedCardCount, 0)
            XCTAssertEqual(result.answers.failureCount, lastFeedback == .again ? 3 : 2)
        }
    }

    func testInvalidatedCompletionIsUnverifiedAndMissingLaterEvidenceIsUnclassified() throws {
        let container = try Support.container(count: 2)
        let service = try WordNoteV3ReviewService(container: container)
        let (lease, _) = try Support.startPresented(service)
        _ = try Support.answer(service, lease: lease)
        let next = try Support.show(service, lease: lease)
        _ = try service.later(next, actionID: UUID(), lease: lease, at: Support.now)
        var payload = try Support.snapshot(container)
        payload.eventStates[0].invalidatedAt = Support.now
        payload.sessions[0].controls = nil
        let result = try ReviewStatisticsBuilder(payload: payload).session(lease.sessionID, at: Support.now)
        XCTAssertEqual(result.processedItems, 2)
        XCTAssertEqual(result.reviewed, 0)
        XCTAssertEqual(result.unverifiedCompleted, 1)
        XCTAssertEqual(result.unclassifiedPostponed, 1)
        XCTAssertEqual(result.manualLater, 0)
        XCTAssertEqual(result.answers.answerCount, 0)
        XCTAssertNil(result.answers.firstRecall.ratio)
    }

    func testFirstRecallUsesSaveOrderAcrossSessionsWhenWallClockMovesBackward() throws {
        let container = try Support.container(count: 1)
        let service = try WordNoteV3ReviewService(container: container)
        let firstTime = Support.now.addingTimeInterval(100)
        let (firstLease, _) = try Support.startPresented(service, at: firstTime)
        _ = try Support.answer(service, lease: firstLease, at: firstTime)
        let card = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewCardModel>()).first)
        card.priorityRequestedAt = firstTime.addingTimeInterval(100)
        try container.mainContext.save()
        let earlier = Support.now.addingTimeInterval(50)
        let (secondLease, _) = try Support.startPresented(service, at: earlier)
        _ = try Support.answer(service, lease: secondLease, feedback: .again, at: earlier)
        let payload = try Support.snapshot(container)
        let stats = try service.statistics(studyTimeZoneID: Support.zone, at: earlier)
        XCTAssertEqual(stats.today.firstRecall, .init(successes: 1, samples: 1))
        XCTAssertEqual(stats.today.clockAnomalyCount, 1)
        XCTAssertEqual(try service.sessionStatistics(secondLease.sessionID).answers.firstRecall.samples, 0)
        XCTAssertEqual(try service.sessionStatistics(firstLease.sessionID).answers.firstRecall.samples, 1)
        var legacyOrder = payload
        for index in legacyOrder.eventStates.indices { legacyOrder.eventStates[index].recordedOrder = nil }
        let estimated = try ReviewStatisticsBuilder(payload: legacyOrder).overview(studyTimeZoneID: Support.zone, at: earlier)
        XCTAssertTrue(estimated.today.hasEstimatedOrder)
        XCTAssertEqual(estimated.today.firstRecall.successes, 0)
        var invalidated = payload
        let firstIndex = try XCTUnwrap(invalidated.eventStates.firstIndex { $0.recordedOrder == 1 })
        invalidated.eventStates[firstIndex].invalidatedAt = firstTime
        XCTAssertEqual(try ReviewStatisticsBuilder(payload: invalidated).overview(studyTimeZoneID: Support.zone,
            at: earlier).today.firstRecall, .init(successes: 0, samples: 1))
    }

    func testFrozenDayKeysAreNotRebucketedOnTimeZoneChanges() throws {
        let now = try ReviewCardTestSupport.date("2026-09-21T16:30:00Z")
        let container = try Support.container(count: 1, at: now)
        let service = try WordNoteV3ReviewService(container: container)
        let (lease, _) = try Support.startPresented(service, at: now)
        _ = try Support.answer(service, lease: lease, at: now)
        XCTAssertEqual(try service.statistics(studyTimeZoneID: Support.zone, at: now).today.answerCount, 1)
        let changed = try service.statistics(studyTimeZoneID: "America/Los_Angeles", at: now)
        XCTAssertEqual(changed.today.answerCount, 0)
        XCTAssertEqual(changed.lifetime.answerCount, 1)
        XCTAssertEqual(changed.studyDayKey, "2026-09-21")
        XCTAssertEqual(try service.statistics(studyTimeZoneID: "America/Los_Angeles",
            at: now.addingTimeInterval(86400)).today.answerCount, 1)
    }

    func testCurrentCourseMembershipAndModeFiltersDoNotDoubleCountGlobalCards() throws {
        let container = try Support.container(count: 1)
        let service = try WordNoteV3ReviewService(container: container)
        let (lease, _) = try Support.startPresented(service)
        _ = try Support.answer(service, lease: lease)
        let payload = try Support.snapshot(container)
        for course in payload.content.content.courses {
            XCTAssertEqual(try service.statistics(courseID: course.id, studyTimeZoneID: Support.zone, at: Support.now).today.answerCount, 1)
        }
        XCTAssertEqual(try service.statistics(studyTimeZoneID: Support.zone, at: Support.now).today.answerCount, 1)
        XCTAssertEqual(try service.statistics(mode: .chineseToEnglish, studyTimeZoneID: Support.zone, at: Support.now).today.answerCount, 0)
        let link = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermCourseLinkModel>()).first)
        let removedCourse = link.courseID
        container.mainContext.delete(link)
        try container.mainContext.save()
        XCTAssertEqual(try service.statistics(courseID: removedCourse, studyTimeZoneID: Support.zone, at: Support.now).today.answerCount, 0)
        XCTAssertEqual(try service.sessionStatistics(lease.sessionID).answers.answerCount, 1)
        XCTAssertThrowsError(try service.statistics(courseID: UUID(), studyTimeZoneID: Support.zone, at: Support.now))
    }

    func testDeletedCardHistorySurvivesButDeletedTermHistoryIsNotInvented() throws {
        let container = try Support.container(count: 1)
        let service = try WordNoteV3ReviewService(container: container)
        let (lease, source) = try Support.startPresented(service)
        _ = try Support.answer(service, lease: lease)
        let writer = try WordNoteV3ContentService(container: container)
        let card = try XCTUnwrap(Support.snapshot(container).cards.first)
        try writer.deleteReviewCard(card.id, expectedRevision: card.revision, at: Support.now)
        XCTAssertEqual(try service.statistics(studyTimeZoneID: Support.zone, at: Support.now).today.completedCardCount, 1)
        let session = try service.sessionStatistics(lease.sessionID)
        XCTAssertEqual(session.unavailable, 1)
        XCTAssertEqual(session.reviewed, 0)
        XCTAssertEqual(session.answers.answerCount, 1)
        let state = try XCTUnwrap(Support.snapshot(container).content.termStates.first { $0.id == source.term.id })
        try writer.deleteTerm(source.term.id, expectedRevision: state.revision, at: Support.now)
        XCTAssertEqual(try service.statistics(studyTimeZoneID: Support.zone, at: Support.now).lifetime.answerCount, 0)
    }

    func testWorkloadSeparatesReadyWaitingNewBuriedAndDisabledCards() throws {
        let container = try Support.container(count: 10)
        let cards = try container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewCardModel>()).sorted { $0.id.uuidString < $1.id.uuidString }
        cards[0].priorityRequestedAt = Support.now
        let presentation = try ReviewCardScheduler().presentation(for: .init(), at: Support.now, studyTimeZoneID: Support.zone)
        let relearning = try ReviewCardScheduler().feedback(.again, for: presentation.after, at: Support.now, studyTimeZoneID: Support.zone)
        relearning.after.apply(to: cards[1])
        ReviewCardSchedule().apply(to: cards[2])
        presentation.after.apply(to: cards[3])
        cards[4].buriedUntil = Support.now.addingTimeInterval(3600)
        cards[4].priorityRequestedAt = Support.now
        cards[5].phaseRaw = "suspended"
        cards[7].nextReviewAt = Support.now.addingTimeInterval(172800)
        cards[8].modeRaw = ReviewMode.chineseToEnglish.rawValue
        let term = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()).first { $0.id == cards[8].termID })
        term.chineseMeaning = nil
        relearning.after.apply(to: cards[9])
        cards[9].nextReviewAt = Support.now
        try container.mainContext.save()
        let service = try WordNoteV3ReviewService(container: container)
        let workload = try service.statistics(studyTimeZoneID: Support.zone, at: Support.now).workload
        XCTAssertEqual(workload.readyCards, 4)
        XCTAssertEqual(workload.waitingRelearningCards, 1)
        XCTAssertEqual(workload.newCards, 1)
        XCTAssertEqual(workload.buriedCards, 1)
        XCTAssertEqual(workload.suspendedCards, 1)
        XCTAssertEqual(workload.missingAnswerCards, 1)
        XCTAssertEqual(workload.pendingPriorityTerms, 2)
        XCTAssertEqual(workload.nextRelearningAt, Support.now.addingTimeInterval(600))
    }

    func testAnswerSequenceOverflowIsAtomicAndInvalidatedEventsDoNotReleaseTheirSequence() throws {
        let container = try Support.container(count: 2)
        let service = try WordNoteV3ReviewService(container: container)
        let (lease, _) = try Support.startPresented(service)
        _ = try Support.answer(service, lease: lease)
        let event = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewEventModel>()).first)
        event.recordedOrder = ReviewStateValidation.maximumCounter
        event.invalidatedAt = Support.now
        try container.mainContext.save()
        let next = try Support.show(service, lease: lease)
        _ = try service.revealAnswer(next, lease: lease, at: Support.now)
        let preview = try service.previewFeedback(.good, lease: lease, at: Support.now)
        let before = try Support.snapshot(container)
        XCTAssertThrowsError(try service.recordFeedback(preview, actionID: UUID(), lease: lease, at: Support.now))
        XCTAssertEqual(try Support.snapshot(container), before)
        event.recordedOrder = 8
        try container.mainContext.save()
        _ = try service.recordFeedback(preview, actionID: UUID(), lease: lease, at: Support.now)
        XCTAssertEqual(try Support.snapshot(container).eventStates.compactMap(\.recordedOrder).sorted(), [8, 9])
    }
}
