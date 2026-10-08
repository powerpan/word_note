import XCTest
@testable import WordNoteCore

enum ReviewCardTestSupport {
    static let zone = "Asia/Hong_Kong"

    static func date(_ value: String = "2026-09-21T04:00:00Z") throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    static func review() throws -> ReviewCardSchedule {
        var value = ReviewCardSchedule()
        value.phase = .review
        value.masteryLevel = .familiar
        value.intervalDays = 7
        value.confidentStreak = 3
        value.lapseCount = 2
        value.nextReviewAt = try date()
        return value
    }

    static func relearning(repeats: Int = 0) throws -> ReviewCardSchedule {
        var value = try review()
        value.phase = .relearning
        value.masteryLevel = .vague
        value.confidentStreak = 0
        value.relearningDayKey = "2026-09-21"
        value.relearningTimeZoneID = zone
        value.relearningRepeatCount = repeats
        return value
    }
}

final class ReviewCardSchedulerTests: XCTestCase {
    private typealias Support = ReviewCardTestSupport
    private let scheduler = ReviewCardScheduler()

    func testAgainAloneCountsAsFailureForNewAndReviewCards() throws {
        let now = try Support.date()
        for before in [ReviewCardSchedule(), try Support.review()] {
            let plan = try scheduler.feedback(.again, for: before, at: now, studyTimeZoneID: Support.zone)
            XCTAssertEqual(plan.before, before)
            XCTAssertEqual(plan.after.phase, .relearning)
            XCTAssertEqual(plan.after.masteryLevel, .vague)
            XCTAssertEqual(plan.after.confidentStreak, 0)
            XCTAssertEqual(plan.after.lapseCount, before.lapseCount + 1)
            XCTAssertEqual(plan.after.nextReviewAt, now.addingTimeInterval(600))
            XCTAssertEqual(plan.after.relearningRepeatCount, 0)
            XCTAssertEqual(plan.delay, .minutes(10))
            XCTAssertEqual(plan.disposition, .relearning)
            XCTAssertTrue(plan.countsAsFailure)
            for feedback in [ReviewFeedback.hard, .good, .easy] {
                let success = try scheduler.feedback(feedback, for: before, at: now, studyTimeZoneID: Support.zone)
                XCTAssertFalse(success.countsAsFailure)
                XCTAssertEqual(success.after.lapseCount, before.lapseCount)
            }
        }
    }

    func testHardUsesFloorAndOneToThreeDayBoundsWithoutAddingFailures() throws {
        let now = try Support.date()
        for (interval, days) in [(0, 1), (1, 1), (2, 1), (5, 2), (6, 3), (1_000_000_000, 3)] {
            var before = try Support.review()
            before.intervalDays = interval
            let plan = try scheduler.feedback(.hard, for: before, at: now, studyTimeZoneID: Support.zone)
            XCTAssertEqual(plan.delay, .calendarDays(days))
            XCTAssertEqual(plan.after.intervalDays, days)
            XCTAssertEqual(plan.after.masteryLevel, .vague)
            XCTAssertEqual(plan.after.confidentStreak, 0)
            XCTAssertEqual(plan.after.lapseCount, before.lapseCount)
            XCTAssertEqual(plan.disposition, .reviewed)
        }
    }

    func testGoodAndEasyKeepLegacyDayCurvesWithoutLegacyFailureSemantics() throws {
        let now = try Support.date()
        let cases = [(0, 0, 2, 4), (1, 2, 4, 7), (2, 4, 7, 14), (3, 0, 2, 2), (3, 20, 30, 40), (5, 50, 30, 60)]
        for (streak, interval, good, easy) in cases {
            for (feedback, days) in [(ReviewFeedback.good, good), (.easy, easy)] {
                var before = try Support.review()
                before.confidentStreak = streak
                before.intervalDays = interval
                let plan = try scheduler.feedback(feedback, for: before, at: now, studyTimeZoneID: Support.zone)
                XCTAssertEqual(plan.delay, .calendarDays(days))
                XCTAssertEqual(plan.after.intervalDays, days)
                XCTAssertEqual(plan.after.confidentStreak, streak + 1)
                XCTAssertEqual(plan.after.masteryLevel, feedback == .good ? .familiar : .mastered)
                XCTAssertEqual(plan.after.lapseCount, before.lapseCount)
            }
        }
        XCTAssertTrue(ReviewScheduler().schedule(after: .hard, reviewedAt: now).countsAsWrong)
    }

    func testPreviewIsDeterministicAndDoesNotPresentOrConsumeQuota() throws {
        let before = ReviewCardSchedule()
        let now = try Support.date()
        let first = try scheduler.feedback(.again, for: before, at: now, studyTimeZoneID: Support.zone)
        for _ in 0..<5 {
            XCTAssertEqual(try scheduler.feedback(.again, for: before, at: now, studyTimeZoneID: Support.zone), first)
        }
        XCTAssertNil(before.introducedAt)
        XCTAssertNil(before.relearningDayKey)
        XCTAssertNil(first.after.introducedAt)
        XCTAssertEqual(first.after.relearningRepeatCount, 0)
    }

    func testNewCardIntroductionIsRecordedOnlyAtFirstPresentation() throws {
        let now = try Support.date()
        let first = try scheduler.presentation(for: .init(), at: now, studyTimeZoneID: Support.zone)
        XCTAssertEqual(first.after.introducedAt, now)
        XCTAssertEqual(first.after.relearningDayKey, "2026-09-21")
        XCTAssertEqual(first.after.relearningRepeatCount, 0)
        XCTAssertFalse(first.isRelearningRepeat)
        let next = try scheduler.presentation(for: first.after, at: now.addingTimeInterval(30), studyTimeZoneID: Support.zone)
        XCTAssertEqual(next.after.introducedAt, now)
        XCTAssertEqual(next.after.relearningRepeatCount, 0)
    }

    func testTwoRelearningPresentationsThenAgainPostponesWithoutSuccessCredit() throws {
        let now = try Support.date()
        let first = try scheduler.presentation(for: Support.review(), at: now, studyTimeZoneID: Support.zone)
        let again = try scheduler.feedback(.again, for: first.after, at: now, studyTimeZoneID: Support.zone)
        let repeatOne = try scheduler.presentation(for: again.after, at: now.addingTimeInterval(600), studyTimeZoneID: Support.zone)
        XCTAssertTrue(repeatOne.isRelearningRepeat)
        XCTAssertEqual(repeatOne.after.relearningRepeatCount, 1)
        let hard = try scheduler.feedback(.hard, for: repeatOne.after, at: now.addingTimeInterval(600), studyTimeZoneID: Support.zone)
        XCTAssertEqual(hard.after.lapseCount, again.after.lapseCount)
        XCTAssertEqual(hard.after.relearningRepeatCount, 1)
        XCTAssertEqual(hard.delay, .minutes(10))
        let repeatTwo = try scheduler.presentation(for: hard.after, at: now.addingTimeInterval(1200), studyTimeZoneID: Support.zone)
        XCTAssertEqual(repeatTwo.after.relearningRepeatCount, 2)
        for feedback in [ReviewFeedback.again, .hard] {
            let capped = try scheduler.feedback(feedback, for: repeatTwo.after, at: now.addingTimeInterval(1200), studyTimeZoneID: Support.zone)
            XCTAssertEqual(capped.disposition, .relearningLimitReached)
            XCTAssertEqual(capped.delay, .calendarDays(1))
            XCTAssertEqual(capped.after.phase, .review)
            XCTAssertEqual(capped.after.masteryLevel, .vague)
            XCTAssertEqual(capped.after.confidentStreak, 0)
            XCTAssertEqual(capped.after.intervalDays, 1)
            XCTAssertEqual(capped.after.nextReviewAt, try Support.date("2026-09-21T16:00:00Z"))
            XCTAssertEqual(capped.after.relearningRepeatCount, 2)
            XCTAssertEqual(capped.after.lapseCount, repeatTwo.after.lapseCount + (feedback == .again ? 1 : 0))
        }
    }

    func testRelearningGoodAndEasyExitWithoutRefundingQuota() throws {
        let now = try Support.date()
        let before = try Support.relearning(repeats: 2)
        for (feedback, days) in [(ReviewFeedback.good, 1), (.easy, 2)] {
            let plan = try scheduler.feedback(feedback, for: before, at: now, studyTimeZoneID: Support.zone)
            XCTAssertEqual(plan.after.phase, .review)
            XCTAssertEqual(plan.after.confidentStreak, 1)
            XCTAssertEqual(plan.after.intervalDays, days)
            XCTAssertEqual(plan.after.relearningRepeatCount, 2)
            XCTAssertEqual(plan.after.relearningDayKey, before.relearningDayKey)
            XCTAssertEqual(plan.disposition, .reviewed)
            let laterFailure = try scheduler.feedback(.again, for: plan.after, at: now.addingTimeInterval(30), studyTimeZoneID: Support.zone)
            XCTAssertEqual(laterFailure.disposition, .relearningLimitReached)
        }
    }

    func testRestoredScheduleAndNewSchedulerCannotResetUsedQuota() throws {
        let before = try Support.relearning(repeats: 2)
        let restored = try JSONDecoder().decode(ReviewCardSchedule.self, from: JSONEncoder().encode(before))
        XCTAssertEqual(restored, before)
        XCTAssertThrowsError(try ReviewCardScheduler().presentation(for: restored, at: Support.date(), studyTimeZoneID: Support.zone)) {
            XCTAssertEqual($0 as? ReviewCardSchedulingError, .relearningLimitReached)
        }
    }

    func testNextDayFirstPresentationResetsBucketButIsNotARepeat() throws {
        let plan = try scheduler.presentation(for: Support.relearning(repeats: 2),
            at: Support.date("2026-09-21T16:00:00Z"), studyTimeZoneID: Support.zone)
        XCTAssertEqual(plan.after.relearningDayKey, "2026-09-22")
        XCTAssertEqual(plan.after.relearningRepeatCount, 0)
        XCTAssertFalse(plan.isRelearningRepeat)
    }

    func testCrossMidnightRelearningStillWaitsFullTenMinutes() throws {
        let now = try Support.date("2026-09-21T15:55:00Z")
        let plan = try scheduler.feedback(.again, for: Support.review(), at: now, studyTimeZoneID: Support.zone)
        let due = try XCTUnwrap(plan.after.nextReviewAt)
        XCTAssertEqual(due, try Support.date("2026-09-21T16:05:00Z"))
        XCTAssertThrowsError(try scheduler.presentation(for: plan.after, at: due.addingTimeInterval(-1), studyTimeZoneID: Support.zone)) {
            XCTAssertEqual($0 as? ReviewCardSchedulingError, .relearningNotDue)
        }
        let presentation = try scheduler.presentation(for: plan.after, at: due, studyTimeZoneID: Support.zone)
        XCTAssertEqual(presentation.after.relearningRepeatCount, 0)
        XCTAssertEqual(presentation.after.relearningDayKey, "2026-09-22")
    }

    func testAnswerAcrossMidnightDoesNotConsumeNextDaysFirstPresentation() throws {
        let presented = try scheduler.presentation(for: Support.relearning(repeats: 1),
            at: Support.date("2026-09-21T15:59:00Z"), studyTimeZoneID: Support.zone)
        XCTAssertEqual(presented.after.relearningRepeatCount, 2)
        let answerTime = try Support.date("2026-09-21T16:01:00Z")
        for feedback in [ReviewFeedback.again, .hard] {
            let answer = try scheduler.feedback(feedback, for: presented.after, at: answerTime, studyTimeZoneID: Support.zone)
            XCTAssertEqual(answer.disposition, .relearning)
            XCTAssertEqual(answer.after.nextReviewAt, answerTime.addingTimeInterval(600))
            XCTAssertEqual(answer.after.relearningDayKey, presented.after.relearningDayKey)
            XCTAssertEqual(answer.after.relearningRepeatCount, 2)
            let firstToday = try scheduler.presentation(for: answer.after, at: answerTime.addingTimeInterval(600), studyTimeZoneID: Support.zone)
            XCTAssertFalse(firstToday.isRelearningRepeat)
            XCTAssertEqual(firstToday.after.relearningDayKey, "2026-09-22")
            XCTAssertEqual(firstToday.after.relearningRepeatCount, 0)
        }
    }

    func testDaySchedulingPreservesLocalTimeAcrossBothDSTTransitions() throws {
        let cases = [("2026-03-07T17:00:00Z", "2026-03-08T16:00:00Z", 23.0),
                     ("2026-10-31T16:00:00Z", "2026-11-01T17:00:00Z", 25.0)]
        for (start, end, hours) in cases {
            let now = try Support.date(start)
            var before = try Support.review()
            before.intervalDays = 1
            let plan = try scheduler.feedback(.hard, for: before, at: now, studyTimeZoneID: "America/New_York")
            XCTAssertEqual(plan.after.nextReviewAt, try Support.date(end))
            XCTAssertEqual(try XCTUnwrap(plan.after.nextReviewAt).timeIntervalSince(now), hours * 3600)
        }
    }

    func testMinuteSchedulingUsesElapsedTimeAcrossBothDSTTransitions() throws {
        for start in ["2026-03-08T06:55:00Z", "2026-11-01T05:55:00Z"] {
            let now = try Support.date(start)
            let plan = try scheduler.feedback(.again, for: Support.review(), at: now, studyTimeZoneID: "America/New_York")
            XCTAssertEqual(plan.after.nextReviewAt, now.addingTimeInterval(600))
        }
    }

    func testDailyCapUsesNextLocalMidnightOnAShortDay() throws {
        var before = try Support.relearning(repeats: 2)
        before.relearningDayKey = "2026-03-08"
        before.relearningTimeZoneID = "America/New_York"
        let plan = try scheduler.feedback(.hard, for: before, at: Support.date("2026-03-08T06:55:00Z"), studyTimeZoneID: "America/New_York")
        XCTAssertEqual(plan.after.nextReviewAt, try Support.date("2026-03-09T04:00:00Z"))
    }

    func testClockRollbackRetainsObservedTimeAndQuotaButClampsDueCalculation() throws {
        var before = try Support.relearning(repeats: 1)
        let highWater = try Support.date()
        before.lastReviewedAt = highWater
        let observed = highWater.addingTimeInterval(-600)
        let plan = try scheduler.feedback(.again, for: before, at: observed, studyTimeZoneID: Support.zone)
        XCTAssertEqual(plan.clock.observedAt, observed)
        XCTAssertEqual(plan.clock.effectiveAt, highWater)
        XCTAssertEqual(plan.clock.anomaly, .movedBackward)
        XCTAssertEqual(plan.after.lastReviewedAt, observed)
        XCTAssertEqual(plan.after.nextReviewAt, highWater.addingTimeInterval(600))
        XCTAssertEqual(plan.after.relearningRepeatCount, 1)
        let next = try scheduler.feedback(.hard, for: plan.after, at: observed.addingTimeInterval(-1),
            studyTimeZoneID: Support.zone, lastInteractionAt: plan.clock.effectiveAt)
        XCTAssertEqual(next.clock.effectiveAt, highWater)
        XCTAssertEqual(next.after.nextReviewAt, highWater.addingTimeInterval(600))
    }

    func testClockRollbackToPreviousDayDoesNotResetBucketOrRewriteEventDay() throws {
        let plan = try scheduler.feedback(.again, for: Support.relearning(repeats: 2),
            at: Support.date("2026-09-20T04:00:00Z"), studyTimeZoneID: Support.zone)
        XCTAssertEqual(plan.clock.studyDayKey, "2026-09-20")
        XCTAssertEqual(plan.clock.anomaly, .movedBackward)
        XCTAssertEqual(plan.after.relearningDayKey, "2026-09-21")
        XCTAssertEqual(plan.after.relearningRepeatCount, 2)
        XCTAssertEqual(plan.after.nextReviewAt, try Support.date("2026-09-21T16:00:00Z"))
    }

    func testTimezoneChangeRetainsOldBucketUntilItsOriginalEnd() throws {
        let before = try Support.relearning(repeats: 2)
        let now = try Support.date()
        let plan = try scheduler.feedback(.again, for: before, at: now, studyTimeZoneID: "America/Los_Angeles")
        XCTAssertEqual(plan.after.relearningTimeZoneID, Support.zone)
        XCTAssertEqual(plan.after.relearningRepeatCount, 2)
        XCTAssertEqual(plan.after.nextReviewAt, try Support.date("2026-09-21T16:00:00Z"))
        let next = try scheduler.presentation(for: before, at: Support.date("2026-09-21T16:00:00Z"), studyTimeZoneID: "America/Los_Angeles")
        XCTAssertEqual(next.after.relearningDayKey, "2026-09-21")
        XCTAssertEqual(next.after.relearningTimeZoneID, "America/Los_Angeles")
        XCTAssertEqual(next.after.relearningRepeatCount, 0)
    }

    func testFeedbackConsumesOnlyPriorityRequestsObservedByThatTime() throws {
        let now = try Support.date()
        for offset in [-1.0, 0, 1] {
            var before = try Support.review()
            before.priorityRequestedAt = now.addingTimeInterval(offset)
            let plan = try scheduler.feedback(.good, for: before, at: now, studyTimeZoneID: Support.zone)
            XCTAssertEqual(plan.after.priorityRequestedAt, offset <= 0 ? nil : before.priorityRequestedAt)
        }
    }

    func testSuspensionAndBurialBlockPresentationAndFeedbackUntilEligible() throws {
        let now = try Support.date()
        for suspended in [false, true] {
            var before = try Support.review()
            if suspended { before.phase = .suspended }
            else { before.buriedUntil = now.addingTimeInterval(1) }
            let expected: ReviewCardSchedulingError = suspended ? .suspended : .buried
            XCTAssertThrowsError(try scheduler.presentation(for: before, at: now, studyTimeZoneID: Support.zone)) {
                XCTAssertEqual($0 as? ReviewCardSchedulingError, expected)
            }
            XCTAssertThrowsError(try scheduler.feedback(.good, for: before, at: now, studyTimeZoneID: Support.zone)) {
                XCTAssertEqual($0 as? ReviewCardSchedulingError, expected)
            }
        }
        var expired = try Support.review()
        expired.buriedUntil = now
        XCTAssertNoThrow(try scheduler.presentation(for: expired, at: now, studyTimeZoneID: Support.zone))
    }

    func testCounterOverflowFailsWithoutWrappingAndHardCanRetainMaximumLapses() throws {
        let now = try Support.date()
        var before = try Support.review()
        before.lapseCount = 1_000_000_000
        before.confidentStreak = 1_000_000_000
        for feedback in [ReviewFeedback.again, .good, .easy] {
            XCTAssertThrowsError(try scheduler.feedback(feedback, for: before, at: now, studyTimeZoneID: Support.zone)) {
                XCTAssertEqual($0 as? ReviewCardSchedulingError, .counterLimit)
            }
        }
        let hard = try scheduler.feedback(.hard, for: before, at: now, studyTimeZoneID: Support.zone)
        XCTAssertEqual(hard.after.lapseCount, 1_000_000_000)
    }

    func testInvalidDatesTimezonesAndMalformedStateFailClosed() throws {
        let now = try Support.date()
        for value in [Double.infinity, -.infinity, .nan, 100_000_000_000] {
            XCTAssertThrowsError(try scheduler.feedback(.good, for: .init(), at: Date(timeIntervalSince1970: value), studyTimeZoneID: Support.zone))
        }
        XCTAssertThrowsError(try scheduler.feedback(.good, for: .init(), at: now, studyTimeZoneID: "Not/A_Zone"))
        var invalid = try Support.review()
        invalid.lapseCount = -1
        XCTAssertThrowsError(try scheduler.feedback(.again, for: invalid, at: now, studyTimeZoneID: Support.zone))
        invalid = try Support.relearning()
        invalid.relearningRepeatCount = 3
        XCTAssertThrowsError(try scheduler.presentation(for: invalid, at: now, studyTimeZoneID: Support.zone))
    }

    func testStudyBucketRejectsImpossibleCivilDaysRatherThanNormalizingThem() throws {
        for (key, zone) in [("2026-02-29", Support.zone), ("2026-04-31", Support.zone),
                            ("2026-13-01", Support.zone), ("0000-01-01", Support.zone),
                            ("2011-12-30", "Pacific/Apia"), ("２０２６-09-21", Support.zone)] {
            XCTAssertThrowsError(try ReviewStudyDay(key: key, timeZoneID: zone))
        }
        XCTAssertNoThrow(try ReviewStudyDay(key: "2024-02-29", timeZoneID: Support.zone))
        XCTAssertThrowsError(try ReviewStudyDay.optional(key: "2026-09-21", timeZoneID: nil, required: false))
        XCTAssertThrowsError(try ReviewStudyDay.optional(key: nil, timeZoneID: nil, required: true))
    }

    func testBCEClockIsNotSilentlyFormattedAsADStudyDay() throws {
        let calendar = try ReviewStudyDay.calendar(timeZoneID: "UTC")
        let ancient = try XCTUnwrap(calendar.date(from: DateComponents(era: 0, year: 1, month: 12, day: 31, hour: 12)))
        XCTAssertThrowsError(try ReviewStudyDay(containing: ancient, timeZoneID: "UTC"))
        XCTAssertThrowsError(try scheduler.feedback(.again, for: .init(), at: ancient, studyTimeZoneID: "UTC"))
    }
}
