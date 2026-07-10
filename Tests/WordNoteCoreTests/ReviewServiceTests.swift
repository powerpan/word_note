import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class ReviewServiceTests: XCTestCase {
    func testDueTermsFiltersAndSorts() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let overdue = TermModel(
            term: "regularization",
            termType: .word,
            chineseMeaning: "正則化",
            importance: .high,
            wrongCount: 1,
            nextReviewAt: now.addingTimeInterval(-60)
        )
        let future = TermModel(
            term: "latent representation",
            termType: .phrase,
            chineseMeaning: "隱含表示",
            nextReviewAt: now.addingTimeInterval(3 * 24 * 60 * 60)
        )
        let dueToday = TermModel(
            term: "gradient descent",
            termType: .phrase,
            chineseMeaning: "梯度下降",
            importance: .medium,
            nextReviewAt: now
        )
        context.insert(overdue)
        context.insert(future)
        context.insert(dueToday)
        try context.save()

        let service = ReviewService(modelContext: context, calendar: .reviewServiceTestCalendar)
        let dueTerms = try service.dueTerms(asOf: now)

        XCTAssertEqual(dueTerms.map { $0.term }, ["regularization", "gradient descent"])
    }

    func testRecordFeedbackCreatesEventAndUpdatesTerm() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let reviewedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let term = TermModel(
            term: "regularization",
            termType: .word,
            chineseMeaning: "正則化",
            masteryLevel: .new,
            nextReviewAt: reviewedAt
        )
        context.insert(term)
        try context.save()
        let service = ReviewService(
            modelContext: context,
            scheduler: ReviewScheduler(calendar: .reviewServiceTestCalendar),
            calendar: .reviewServiceTestCalendar
        )

        let event = try service.recordFeedback(for: term, feedback: ReviewFeedback.again, reviewedAt: reviewedAt)

        XCTAssertEqual(term.reviewCount, 1)
        XCTAssertEqual(term.wrongCount, 1)
        XCTAssertEqual(term.masteryLevel, .vague)
        XCTAssertEqual(term.reviewIntervalDays, 1)
        XCTAssertEqual(term.correctStreak, 0)
        XCTAssertEqual(term.lastReviewedAt, reviewedAt)
        XCTAssertEqual(event.previousMasteryLevel, MasteryLevel.new)
        XCTAssertEqual(event.newMasteryLevel, MasteryLevel.vague)
        XCTAssertEqual(event.feedback, ReviewFeedback.again)

        let events = try context.fetch(FetchDescriptor<ReviewEventModel>())
        XCTAssertEqual(events.count, 1)
    }

    func testRecordFeedbackUsesExistingStreakForAdaptiveSchedule() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let reviewedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let term = TermModel(
            term: "regularization",
            termType: .word,
            chineseMeaning: "正則化",
            masteryLevel: .familiar,
            reviewIntervalDays: 4,
            correctStreak: 2,
            nextReviewAt: reviewedAt
        )
        context.insert(term)
        try context.save()
        let service = ReviewService(
            modelContext: context,
            scheduler: ReviewScheduler(calendar: .reviewServiceTestCalendar),
            calendar: .reviewServiceTestCalendar
        )

        try service.recordFeedback(for: term, feedback: .good, reviewedAt: reviewedAt)

        XCTAssertEqual(term.masteryLevel, .familiar)
        XCTAssertEqual(term.correctStreak, 3)
        XCTAssertEqual(term.reviewIntervalDays, 7)
        XCTAssertEqual(term.nextReviewAt, Calendar.reviewServiceTestCalendar.date(byAdding: .day, value: 7, to: reviewedAt))
    }

    func testPostponeUntilTomorrowDoesNotCreateReviewEvent() throws {
        let context = ModelContext(try makeInMemoryContainer())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let term = TermModel(
            term: "regularization",
            termType: .word,
            chineseMeaning: "正則化",
            wrongCount: 2,
            nextReviewAt: now
        )
        context.insert(term)
        try context.save()
        let service = ReviewService(
            modelContext: context,
            calendar: .reviewServiceTestCalendar
        )

        try service.postponeUntilTomorrow(term, from: now)

        let startOfToday = Calendar.reviewServiceTestCalendar.startOfDay(for: now)
        XCTAssertEqual(
            term.nextReviewAt,
            Calendar.reviewServiceTestCalendar.date(byAdding: .day, value: 1, to: startOfToday)
        )
        XCTAssertEqual(term.reviewCount, 0)
        XCTAssertEqual(term.wrongCount, 2)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ReviewEventModel>()).isEmpty)
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            CourseModel.self,
            InputRecordModel.self,
            CandidateTermModel.self,
            TermModel.self,
            ReviewEventModel.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

private extension Calendar {
    static var reviewServiceTestCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
