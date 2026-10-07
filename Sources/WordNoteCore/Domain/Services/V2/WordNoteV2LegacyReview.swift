import Foundation

extension WordNoteV2ContentService {
    /// A02 preserves the existing mixed counters. V3 changes scheduling and event semantics together.
    public func recordLegacyFeedback(
        termID: UUID, expectedRevision: Int, mode: ReviewMode, feedback: ReviewFeedback,
        at date: Date = Date(), calendar: Calendar = .current
    ) throws {
        try transaction {
            try validateDate(date)
            let value = try term(termID)
            try requireRevision(value.revision, expectedRevision)
            guard value.counterSemanticsVersionRaw == "legacyMixed",
                  (0...1_000_000_000).contains(value.reviewIntervalDays) else { throw WordNoteV2ContentError.invalidState }
            if feedback == .good || feedback == .easy { _ = try increment(value.correctStreak) }
            let result = ReviewScheduler(calendar: calendar).schedule(
                after: feedback, reviewedAt: date, currentIntervalDays: value.reviewIntervalDays,
                currentCorrectStreak: value.correctStreak
            )
            try validateDate(result.nextReviewAt)
            context.insert(ReviewEvent(
                termID: value.id, mode: mode, feedback: feedback,
                previousMasteryLevel: value.masteryLevel, newMasteryLevel: result.masteryLevel,
                previousNextReviewAt: value.nextReviewAt, newNextReviewAt: result.nextReviewAt, reviewedAt: date
            ))
            value.masteryLevel = result.masteryLevel
            value.nextReviewAt = result.nextReviewAt
            value.reviewIntervalDays = result.reviewIntervalDays
            value.correctStreak = result.correctStreak
            value.reviewCount = try increment(value.reviewCount)
            if result.countsAsWrong { value.wrongCount = try increment(value.wrongCount) }
            value.lastReviewedAt = date
            try touch(value, at: date)
        }
    }

    public func postponeLegacyReview(
        termID: UUID, expectedRevision: Int, from date: Date = Date(), calendar: Calendar = .current
    ) throws {
        try transaction {
            try validateDate(date)
            let value = try term(termID)
            try requireRevision(value.revision, expectedRevision)
            guard value.counterSemanticsVersionRaw == "legacyMixed" else { throw WordNoteV2ContentError.invalidState }
            let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
                ?? date.addingTimeInterval(86_400)
            try validateDate(next)
            value.nextReviewAt = next
            try touch(value, at: date)
        }
    }
}
