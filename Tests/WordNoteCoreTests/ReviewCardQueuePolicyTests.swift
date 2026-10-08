import XCTest
@testable import WordNoteCore

final class ReviewCardQueuePolicyTests: XCTestCase {
    private typealias Support = ReviewCardTestSupport
    private let policy = ReviewCardQueuePolicy()

    func testDailyDueIncludesLaterTodayButExcludesTomorrowBoundary() throws {
        let now = try Support.date()
        let tomorrow = try Support.date("2026-09-21T16:00:00Z")
        var card = try Support.review()
        for (due, expected) in [(now.addingTimeInterval(-1), ReviewCardAvailability.due),
                                (tomorrow.addingTimeInterval(-1), .due), (tomorrow, .notDue)] {
            card.nextReviewAt = due
            XCTAssertEqual(try policy.availability(of: card, at: now, studyTimeZoneID: Support.zone), expected)
        }
    }

    func testPriorityDoesNotSkipMinuteWaitAndExactDueIsEligible() throws {
        let now = try Support.date()
        var card = try Support.relearning()
        card.nextReviewAt = now.addingTimeInterval(600)
        card.priorityRequestedAt = now
        XCTAssertEqual(try policy.availability(of: card, at: now.addingTimeInterval(599), studyTimeZoneID: Support.zone),
            .relearningWaiting(until: now.addingTimeInterval(600)))
        XCTAssertEqual(try policy.availability(of: card, at: now.addingTimeInterval(600), studyTimeZoneID: Support.zone), .relearningDue)
    }

    func testPriorityOverridesDailyDueButNeverSuspensionOrBurial() throws {
        let now = try Support.date()
        var card = try Support.review()
        card.nextReviewAt = now.addingTimeInterval(864_000)
        card.priorityRequestedAt = now
        XCTAssertEqual(try policy.availability(of: card, at: now, studyTimeZoneID: Support.zone), .priority)
        card.buriedUntil = now.addingTimeInterval(1)
        XCTAssertEqual(try policy.availability(of: card, at: now, studyTimeZoneID: Support.zone), .buried(until: now.addingTimeInterval(1)))
        XCTAssertEqual(try policy.availability(of: card, at: now.addingTimeInterval(1), studyTimeZoneID: Support.zone), .priority)
        card.phase = .suspended
        XCTAssertEqual(try policy.availability(of: card, at: now, studyTimeZoneID: Support.zone), .suspended)
    }

    func testNewPriorityCardStillRequiresNewCardQuota() throws {
        let now = try Support.date()
        var card = ReviewCardSchedule()
        card.priorityRequestedAt = now
        let availability = try policy.availability(of: card, at: now, studyTimeZoneID: Support.zone)
        XCTAssertEqual(availability, .newCard)
        XCTAssertFalse(availability.isScheduledNow)
    }

    func testRelearningCapSurvivesTimezoneChangeAndResetsOnlyAfterOldBucketEnds() throws {
        let card = try Support.relearning(repeats: 2)
        let boundary = try Support.date("2026-09-21T16:00:00Z")
        XCTAssertEqual(try policy.availability(of: card, at: Support.date(), studyTimeZoneID: "America/Los_Angeles"),
            .relearningLimit(until: boundary))
        XCTAssertEqual(try policy.availability(of: card, at: boundary, studyTimeZoneID: "America/Los_Angeles"), .relearningDue)
        XCTAssertEqual(card.relearningRepeatCount, 2)
        XCTAssertEqual(card.relearningTimeZoneID, Support.zone)
    }

    func testClockHighWaterDoesNotMakeMinuteCardDueEarly() throws {
        let now = try Support.date()
        var card = try Support.relearning()
        card.nextReviewAt = now.addingTimeInterval(600)
        XCTAssertEqual(try policy.availability(of: card, at: now, studyTimeZoneID: Support.zone,
            lastInteractionAt: now.addingTimeInterval(1200)), .relearningWaiting(until: now.addingTimeInterval(600)))
    }

    func testClassificationDoesNotMutateScheduleOrUseQuota() throws {
        let now = try Support.date()
        let card = try Support.relearning(repeats: 1)
        let original = card
        for _ in 0..<5 {
            XCTAssertEqual(try policy.availability(of: card, at: now, studyTimeZoneID: Support.zone), .relearningDue)
        }
        XCTAssertEqual(card, original)
    }

    func testUnknownClockOrInvalidScheduleIsNotClassifiedAsAvailable() throws {
        let now = try Support.date()
        XCTAssertThrowsError(try policy.availability(of: .init(), at: now, studyTimeZoneID: "Unknown"))
        var card = try Support.relearning()
        card.relearningDayKey = nil
        XCTAssertThrowsError(try policy.availability(of: card, at: now, studyTimeZoneID: Support.zone))
    }

    func testOnlyDueAndPriorityCategoriesAreImmediatelyScheduled() throws {
        let now = try Support.date()
        for value in [ReviewCardAvailability.due, .priority, .relearningDue] { XCTAssertTrue(value.isScheduledNow) }
        for value in [ReviewCardAvailability.suspended, .buried(until: now), .relearningWaiting(until: now),
                      .relearningLimit(until: now), .newCard, .notDue] { XCTAssertFalse(value.isScheduledNow) }
    }
}
