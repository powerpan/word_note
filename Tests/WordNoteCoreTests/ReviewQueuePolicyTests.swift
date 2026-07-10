import XCTest
@testable import WordNoteCore

final class ReviewQueuePolicyTests: XCTestCase {
    func testDueQueueIncludesTodayAndSortsDuplicateHitsAfterWrongCount() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let lowPriority = TermModel(
            term: "low priority",
            termType: .phrase,
            chineseMeaning: "低優先級",
            wrongCount: 1,
            duplicateHitCount: 0,
            nextReviewAt: now
        )
        let duplicateHit = TermModel(
            term: "duplicate hit",
            termType: .phrase,
            chineseMeaning: "重複命中",
            wrongCount: 1,
            duplicateHitCount: 3,
            nextReviewAt: now
        )
        let future = TermModel(
            term: "future",
            termType: .word,
            chineseMeaning: "未來",
            nextReviewAt: now.addingTimeInterval(3 * 24 * 60 * 60)
        )

        let result = ReviewQueuePolicy().terms(
            from: [lowPriority, future, duplicateHit],
            asOf: now,
            calendar: .reviewQueueTestCalendar
        )

        XCTAssertEqual(result.map(\.term), ["duplicate hit", "low priority"])
    }

    func testWeakQueueIncludesNonDueMistakesAndSortsByWeakness() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let wrong = TermModel(
            term: "wrong",
            termType: .word,
            chineseMeaning: "錯誤",
            wrongCount: 4,
            nextReviewAt: now.addingTimeInterval(30 * 24 * 60 * 60)
        )
        let duplicate = TermModel(
            term: "duplicate",
            termType: .word,
            chineseMeaning: "重複",
            duplicateHitCount: 2,
            nextReviewAt: nil
        )
        let mastered = TermModel(
            term: "mastered",
            termType: .word,
            chineseMeaning: "已掌握",
            masteryLevel: .mastered,
            nextReviewAt: now
        )

        let result = ReviewQueuePolicy().terms(
            from: [duplicate, mastered, wrong],
            scope: .weakTerms,
            asOf: now,
            calendar: .reviewQueueTestCalendar
        )

        XCTAssertEqual(result.map(\.term), ["wrong", "duplicate"])
    }
}

private extension Calendar {
    static var reviewQueueTestCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
