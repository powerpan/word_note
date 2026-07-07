import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class ModelTests: XCTestCase {
    func testInputRecordStatusTransitions() {
        let record = InputRecordModel(rawText: " Latent   Representation ", sourceType: .paper)

        XCTAssertEqual(record.normalizedText, "latent representation")
        XCTAssertEqual(record.status, .draft)
        XCTAssertEqual(record.sourceType, .paper)

        record.markAnalyzing()
        XCTAssertEqual(record.status, .analyzing)
        XCTAssertNil(record.aiErrorSummary)

        record.markFailed("timeout")
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.aiErrorSummary, "timeout")

        record.markAnalyzed(sentenceMeaning: "模型學習隱含表示。", inputType: .sentence)
        XCTAssertEqual(record.status, .analyzed)
        XCTAssertEqual(record.inputType, .sentence)
        XCTAssertNil(record.aiErrorSummary)
        XCTAssertNotNil(record.analyzedAt)
    }

    func testTermReviewUpdateAppliesSchedulerResult() {
        let reviewedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let nextReviewAt = reviewedAt.addingTimeInterval(24 * 60 * 60)
        let term = TermModel(term: "regularization", termType: .word)
        let result = ReviewScheduleResult(
            masteryLevel: .vague,
            nextReviewAt: nextReviewAt,
            countsAsWrong: true
        )

        term.applyReview(result, reviewedAt: reviewedAt)

        XCTAssertEqual(term.reviewCount, 1)
        XCTAssertEqual(term.wrongCount, 1)
        XCTAssertEqual(term.masteryLevel, .vague)
        XCTAssertEqual(term.lastReviewedAt, reviewedAt)
        XCTAssertEqual(term.nextReviewAt, nextReviewAt)
    }

    func testSwiftDataContainerStoresCourseAndTerm() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let course = CourseModel(courseName: "Machine Learning", courseCode: "COMP 5212")
        let term = TermModel(
            term: "gradient descent",
            termType: .phrase,
            chineseMeaning: "梯度下降",
            courseID: course.id,
            sourceType: .class
        )

        context.insert(course)
        context.insert(term)
        try context.save()

        let courses = try context.fetch(FetchDescriptor<CourseModel>())
        let terms = try context.fetch(FetchDescriptor<TermModel>())

        XCTAssertEqual(courses.map(\.courseName), ["Machine Learning"])
        XCTAssertEqual(terms.map(\.normalizedTerm), ["gradient descent"])
        XCTAssertEqual(terms.first?.courseID, course.id)
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
