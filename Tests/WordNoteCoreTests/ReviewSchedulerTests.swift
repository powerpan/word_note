import XCTest
@testable import WordNoteCore

final class ReviewSchedulerTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testAgainSchedulesTomorrowAndCountsWrong() {
        let result = ReviewScheduler(calendar: .gregorianUTC).schedule(after: .again, reviewedAt: referenceDate)

        XCTAssertEqual(result.masteryLevel, .vague)
        XCTAssertTrue(result.countsAsWrong)
        XCTAssertEqual(result.nextReviewAt, Calendar.gregorianUTC.date(byAdding: .day, value: 1, to: referenceDate))
    }

    func testHardSchedulesThreeDaysAndCountsWrong() {
        let result = ReviewScheduler(calendar: .gregorianUTC).schedule(after: .hard, reviewedAt: referenceDate)

        XCTAssertEqual(result.masteryLevel, .vague)
        XCTAssertTrue(result.countsAsWrong)
        XCTAssertEqual(result.nextReviewAt, Calendar.gregorianUTC.date(byAdding: .day, value: 3, to: referenceDate))
    }

    func testGoodSchedulesSevenDays() {
        let result = ReviewScheduler(calendar: .gregorianUTC).schedule(after: .good, reviewedAt: referenceDate)

        XCTAssertEqual(result.masteryLevel, .familiar)
        XCTAssertFalse(result.countsAsWrong)
        XCTAssertEqual(result.nextReviewAt, Calendar.gregorianUTC.date(byAdding: .day, value: 7, to: referenceDate))
    }

    func testEasySchedulesFourteenDays() {
        let result = ReviewScheduler(calendar: .gregorianUTC).schedule(after: .easy, reviewedAt: referenceDate)

        XCTAssertEqual(result.masteryLevel, .mastered)
        XCTAssertFalse(result.countsAsWrong)
        XCTAssertEqual(result.nextReviewAt, Calendar.gregorianUTC.date(byAdding: .day, value: 14, to: referenceDate))
    }
}

private extension Calendar {
    static var gregorianUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
