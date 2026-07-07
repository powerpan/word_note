import Foundation

public struct ReviewScheduleResult: Equatable {
    public let masteryLevel: MasteryLevel
    public let nextReviewAt: Date
    public let countsAsWrong: Bool

    public init(masteryLevel: MasteryLevel, nextReviewAt: Date, countsAsWrong: Bool) {
        self.masteryLevel = masteryLevel
        self.nextReviewAt = nextReviewAt
        self.countsAsWrong = countsAsWrong
    }
}

public struct ReviewScheduler {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func schedule(after feedback: ReviewFeedback, reviewedAt: Date = Date()) -> ReviewScheduleResult {
        let days: Int
        let masteryLevel: MasteryLevel
        let countsAsWrong: Bool

        switch feedback {
        case .again:
            days = 1
            masteryLevel = .vague
            countsAsWrong = true
        case .hard:
            days = 3
            masteryLevel = .vague
            countsAsWrong = true
        case .good:
            days = 7
            masteryLevel = .familiar
            countsAsWrong = false
        case .easy:
            days = 14
            masteryLevel = .mastered
            countsAsWrong = false
        }

        let nextDate = calendar.date(byAdding: .day, value: days, to: reviewedAt) ?? reviewedAt
        return ReviewScheduleResult(
            masteryLevel: masteryLevel,
            nextReviewAt: nextDate,
            countsAsWrong: countsAsWrong
        )
    }
}
