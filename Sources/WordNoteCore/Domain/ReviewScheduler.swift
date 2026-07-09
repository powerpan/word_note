import Foundation

public struct ReviewScheduleResult: Equatable {
    public let masteryLevel: MasteryLevel
    public let nextReviewAt: Date
    public let reviewIntervalDays: Int
    public let correctStreak: Int
    public let countsAsWrong: Bool

    public init(
        masteryLevel: MasteryLevel,
        nextReviewAt: Date,
        reviewIntervalDays: Int = 0,
        correctStreak: Int = 0,
        countsAsWrong: Bool
    ) {
        self.masteryLevel = masteryLevel
        self.nextReviewAt = nextReviewAt
        self.reviewIntervalDays = reviewIntervalDays
        self.correctStreak = correctStreak
        self.countsAsWrong = countsAsWrong
    }
}

public struct ReviewScheduler {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func schedule(
        after feedback: ReviewFeedback,
        reviewedAt: Date = Date(),
        currentIntervalDays: Int = 0,
        currentCorrectStreak: Int = 0
    ) -> ReviewScheduleResult {
        let days: Int
        let masteryLevel: MasteryLevel
        let nextCorrectStreak: Int
        let countsAsWrong: Bool

        switch feedback {
        case .again:
            days = 1
            masteryLevel = .vague
            nextCorrectStreak = 0
            countsAsWrong = true
        case .hard:
            days = min(max(1, currentIntervalDays / 2), 3)
            masteryLevel = .vague
            nextCorrectStreak = 0
            countsAsWrong = true
        case .good:
            days = Self.goodIntervalDays(
                currentIntervalDays: currentIntervalDays,
                currentCorrectStreak: currentCorrectStreak
            )
            masteryLevel = .familiar
            nextCorrectStreak = currentCorrectStreak + 1
            countsAsWrong = false
        case .easy:
            days = Self.easyIntervalDays(
                currentIntervalDays: currentIntervalDays,
                currentCorrectStreak: currentCorrectStreak
            )
            masteryLevel = .mastered
            nextCorrectStreak = currentCorrectStreak + 1
            countsAsWrong = false
        }

        let nextDate = calendar.date(byAdding: .day, value: days, to: reviewedAt) ?? reviewedAt
        return ReviewScheduleResult(
            masteryLevel: masteryLevel,
            nextReviewAt: nextDate,
            reviewIntervalDays: days,
            correctStreak: nextCorrectStreak,
            countsAsWrong: countsAsWrong
        )
    }

    private static func goodIntervalDays(currentIntervalDays: Int, currentCorrectStreak: Int) -> Int {
        switch currentCorrectStreak {
        case ..<1:
            return 2
        case 1:
            return 4
        case 2:
            return 7
        default:
            return min(max(currentIntervalDays, 1) * 2, 30)
        }
    }

    private static func easyIntervalDays(currentIntervalDays: Int, currentCorrectStreak: Int) -> Int {
        switch currentCorrectStreak {
        case ..<1:
            return 4
        case 1:
            return 7
        case 2:
            return 14
        default:
            return min(max(currentIntervalDays, 1) * 2, 60)
        }
    }
}
