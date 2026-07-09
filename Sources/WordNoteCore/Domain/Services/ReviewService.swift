import Foundation
import SwiftData

@MainActor
public struct ReviewService {
    private let modelContext: ModelContext
    private let scheduler: ReviewScheduler
    private let calendar: Calendar

    public init(
        modelContext: ModelContext,
        scheduler: ReviewScheduler = ReviewScheduler(),
        calendar: Calendar = .current
    ) {
        self.modelContext = modelContext
        self.scheduler = scheduler
        self.calendar = calendar
    }

    public func dueTerms(asOf date: Date = Date(), courseID: UUID? = nil) throws -> [TermModel] {
        let terms = try modelContext.fetch(FetchDescriptor<TermModel>())
        let endOfDay = calendar.startOfDay(for: date).addingTimeInterval(24 * 60 * 60)

        return terms
            .filter { term in
                guard let nextReviewAt = term.nextReviewAt else { return false }
                let courseMatches = courseID == nil || term.courseID == courseID
                return courseMatches && nextReviewAt < endOfDay
            }
            .sorted { lhs, rhs in
                if lhs.nextReviewAt != rhs.nextReviewAt {
                    return (lhs.nextReviewAt ?? .distantFuture) < (rhs.nextReviewAt ?? .distantFuture)
                }
                if lhs.wrongCount != rhs.wrongCount {
                    return lhs.wrongCount > rhs.wrongCount
                }
                if lhs.duplicateHitCount != rhs.duplicateHitCount {
                    return lhs.duplicateHitCount > rhs.duplicateHitCount
                }
                if lhs.importance != rhs.importance {
                    return lhs.importance > rhs.importance
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    @discardableResult
    public func recordFeedback(
        for term: TermModel,
        mode: ReviewMode = .englishToChinese,
        feedback: ReviewFeedback,
        reviewedAt: Date = Date()
    ) throws -> ReviewEventModel {
        let previousMasteryLevel = term.masteryLevel
        let previousNextReviewAt = term.nextReviewAt
        let result = scheduler.schedule(
            after: feedback,
            reviewedAt: reviewedAt,
            currentIntervalDays: term.reviewIntervalDays,
            currentCorrectStreak: term.correctStreak
        )

        term.applyReview(result, reviewedAt: reviewedAt)

        let event = ReviewEventModel(
            termID: term.id,
            mode: mode,
            feedback: feedback,
            previousMasteryLevel: previousMasteryLevel,
            newMasteryLevel: term.masteryLevel,
            previousNextReviewAt: previousNextReviewAt,
            newNextReviewAt: term.nextReviewAt,
            reviewedAt: reviewedAt
        )
        modelContext.insert(event)
        try modelContext.save()
        return event
    }
}
