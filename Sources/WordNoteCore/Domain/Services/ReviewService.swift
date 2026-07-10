import Foundation
import SwiftData

@MainActor
public struct ReviewService {
    private let modelContext: ModelContext
    private let scheduler: ReviewScheduler
    private let calendar: Calendar
    private let queuePolicy: ReviewQueuePolicy

    public init(
        modelContext: ModelContext,
        scheduler: ReviewScheduler = ReviewScheduler(),
        calendar: Calendar = .current,
        queuePolicy: ReviewQueuePolicy = ReviewQueuePolicy()
    ) {
        self.modelContext = modelContext
        self.scheduler = scheduler
        self.calendar = calendar
        self.queuePolicy = queuePolicy
    }

    public func dueTerms(asOf date: Date = Date(), courseID: UUID? = nil) throws -> [TermModel] {
        let terms = try modelContext.fetch(FetchDescriptor<TermModel>())
        return queuePolicy.terms(
            from: terms,
            scope: .dueToday,
            asOf: date,
            courseID: courseID,
            calendar: calendar
        )
    }

    public func weakTerms(asOf date: Date = Date(), courseID: UUID? = nil) throws -> [TermModel] {
        let terms = try modelContext.fetch(FetchDescriptor<TermModel>())
        return queuePolicy.terms(
            from: terms,
            scope: .weakTerms,
            asOf: date,
            courseID: courseID,
            calendar: calendar
        )
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

    public func postponeUntilTomorrow(_ term: TermModel, from date: Date = Date()) throws {
        let startOfToday = calendar.startOfDay(for: date)
        term.nextReviewAt = calendar.date(byAdding: .day, value: 1, to: startOfToday)
            ?? date.addingTimeInterval(24 * 60 * 60)
        term.touch(date)
        try modelContext.save()
    }
}
