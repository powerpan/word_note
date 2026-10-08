import XCTest
@testable import WordNoteCore

final class ReviewCardPostponementTests: XCTestCase {
    func testLaterUsesTrueLocalMidnightAcrossBothDSTChanges() throws {
        for (date, expected) in [("2026-03-08T06:00:00Z", "2026-03-09T04:00:00Z"),
                                 ("2026-11-01T05:00:00Z", "2026-11-02T05:00:00Z")] {
            let now = try ReviewCardTestSupport.date(date)
            let plan = try ReviewCardScheduler().postpone(.init(), at: now, studyTimeZoneID: "America/New_York")
            XCTAssertEqual(plan.after.nextReviewAt, try ReviewCardTestSupport.date(expected))
            XCTAssertEqual(plan.after.masteryLevel, .new)
            XCTAssertNil(plan.after.lastReviewedAt)
            XCTAssertEqual(plan.after.lapseCount, 0)
        }
    }

    func testRollbackPreservesFuturePriorityAndCannotMoveDueBehindHighWater() throws {
        let now = try ReviewCardTestSupport.date("2026-09-21T12:00:00Z")
        var schedule = ReviewCardSchedule()
        schedule.priorityRequestedAt = now
        let plan = try ReviewCardScheduler().postpone(schedule, at: now.addingTimeInterval(-86400),
            studyTimeZoneID: "Asia/Hong_Kong", lastInteractionAt: now)
        XCTAssertEqual(plan.clock.anomaly, .movedBackward)
        XCTAssertEqual(plan.after.priorityRequestedAt, now)
        XCTAssertEqual(plan.after.nextReviewAt, try ReviewCardTestSupport.date("2026-09-21T16:00:00Z"))
        let consumed = try ReviewCardScheduler().postpone(schedule, at: now, studyTimeZoneID: "Asia/Hong_Kong")
        XCTAssertNil(consumed.after.priorityRequestedAt)
    }

    func testTimezoneSwitchWaitsForExistingRelearningBucketAndPreservesAbility() throws {
        let now = try ReviewCardTestSupport.date("2026-09-21T15:00:00Z")
        let scheduler = ReviewCardScheduler()
        let shown = try scheduler.presentation(for: .init(), at: now, studyTimeZoneID: "America/Los_Angeles")
        let failed = try scheduler.feedback(.again, for: shown.after, at: now, studyTimeZoneID: "America/Los_Angeles")
        let plan = try scheduler.postpone(failed.after, at: now, studyTimeZoneID: "Asia/Hong_Kong")
        var expected = failed.after
        expected.nextReviewAt = try ReviewCardTestSupport.date("2026-09-22T07:00:00Z")
        XCTAssertEqual(plan.after, expected)
    }

    func testInvalidDisabledAndBuriedCardsAreNotPostponed() throws {
        var schedule = ReviewCardSchedule()
        let now = Date()
        schedule.phase = .suspended
        XCTAssertThrowsError(try ReviewCardScheduler().postpone(schedule, at: now, studyTimeZoneID: "UTC"))
        schedule = .init()
        schedule.buriedUntil = now.addingTimeInterval(60)
        XCTAssertThrowsError(try ReviewCardScheduler().postpone(schedule, at: now, studyTimeZoneID: "UTC"))
        XCTAssertThrowsError(try ReviewCardScheduler().postpone(.init(), at: now, studyTimeZoneID: "invalid"))
    }
}
