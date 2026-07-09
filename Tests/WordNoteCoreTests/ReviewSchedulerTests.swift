import XCTest
@testable import WordNoteCore

final class ReviewSchedulerTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testAgainSchedulesTomorrowAndCountsWrong() {
        let result = ReviewScheduler(calendar: .gregorianUTC).schedule(after: .again, reviewedAt: referenceDate)

        XCTAssertEqual(result.masteryLevel, .vague)
        XCTAssertTrue(result.countsAsWrong)
        XCTAssertEqual(result.reviewIntervalDays, 1)
        XCTAssertEqual(result.correctStreak, 0)
        XCTAssertEqual(result.nextReviewAt, Calendar.gregorianUTC.date(byAdding: .day, value: 1, to: referenceDate))
    }

    func testHardSchedulesOneToThreeDaysAndCountsWrong() {
        let result = ReviewScheduler(calendar: .gregorianUTC).schedule(after: .hard, reviewedAt: referenceDate)

        XCTAssertEqual(result.masteryLevel, .vague)
        XCTAssertTrue(result.countsAsWrong)
        XCTAssertEqual(result.reviewIntervalDays, 1)
        XCTAssertEqual(result.correctStreak, 0)
        XCTAssertEqual(result.nextReviewAt, Calendar.gregorianUTC.date(byAdding: .day, value: 1, to: referenceDate))

        let cappedResult = ReviewScheduler(calendar: .gregorianUTC).schedule(
            after: .hard,
            reviewedAt: referenceDate,
            currentIntervalDays: 10,
            currentCorrectStreak: 3
        )

        XCTAssertEqual(cappedResult.reviewIntervalDays, 3)
        XCTAssertEqual(cappedResult.correctStreak, 0)
        XCTAssertEqual(cappedResult.nextReviewAt, Calendar.gregorianUTC.date(byAdding: .day, value: 3, to: referenceDate))
    }

    func testGoodUsesProgressiveIntervals() {
        let result = ReviewScheduler(calendar: .gregorianUTC).schedule(after: .good, reviewedAt: referenceDate)

        XCTAssertEqual(result.masteryLevel, .familiar)
        XCTAssertFalse(result.countsAsWrong)
        XCTAssertEqual(result.reviewIntervalDays, 2)
        XCTAssertEqual(result.correctStreak, 1)
        XCTAssertEqual(result.nextReviewAt, Calendar.gregorianUTC.date(byAdding: .day, value: 2, to: referenceDate))

        let streakTwoResult = ReviewScheduler(calendar: .gregorianUTC).schedule(
            after: .good,
            reviewedAt: referenceDate,
            currentIntervalDays: 4,
            currentCorrectStreak: 2
        )

        XCTAssertEqual(streakTwoResult.reviewIntervalDays, 7)
        XCTAssertEqual(streakTwoResult.correctStreak, 3)

        let cappedResult = ReviewScheduler(calendar: .gregorianUTC).schedule(
            after: .good,
            reviewedAt: referenceDate,
            currentIntervalDays: 20,
            currentCorrectStreak: 3
        )

        XCTAssertEqual(cappedResult.reviewIntervalDays, 30)
        XCTAssertEqual(cappedResult.correctStreak, 4)
    }

    func testEasyUsesProgressiveIntervals() {
        let result = ReviewScheduler(calendar: .gregorianUTC).schedule(after: .easy, reviewedAt: referenceDate)

        XCTAssertEqual(result.masteryLevel, .mastered)
        XCTAssertFalse(result.countsAsWrong)
        XCTAssertEqual(result.reviewIntervalDays, 4)
        XCTAssertEqual(result.correctStreak, 1)
        XCTAssertEqual(result.nextReviewAt, Calendar.gregorianUTC.date(byAdding: .day, value: 4, to: referenceDate))

        let streakTwoResult = ReviewScheduler(calendar: .gregorianUTC).schedule(
            after: .easy,
            reviewedAt: referenceDate,
            currentIntervalDays: 7,
            currentCorrectStreak: 2
        )

        XCTAssertEqual(streakTwoResult.reviewIntervalDays, 14)
        XCTAssertEqual(streakTwoResult.correctStreak, 3)

        let cappedResult = ReviewScheduler(calendar: .gregorianUTC).schedule(
            after: .easy,
            reviewedAt: referenceDate,
            currentIntervalDays: 40,
            currentCorrectStreak: 3
        )

        XCTAssertEqual(cappedResult.reviewIntervalDays, 60)
        XCTAssertEqual(cappedResult.correctStreak, 4)
    }
}

private extension Calendar {
    static var gregorianUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
