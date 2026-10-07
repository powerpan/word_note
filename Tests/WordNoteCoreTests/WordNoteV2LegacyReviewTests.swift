import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2LegacyReviewTests: XCTestCase {
    private typealias Support = WordNoteV2ServiceTestSupport

    func testAllFeedbackKeepsLegacySchedulerAndWritesAnEventWithOneRevision() throws {
        for feedback in ReviewFeedback.allCases {
            let container = try Support.container()
            let term = try Support.term("quick", in: container)
            let old = WordNoteSnapshotPayload.Term(term)
            let expected = ReviewScheduler().schedule(after: feedback, reviewedAt: Support.now, currentIntervalDays: term.reviewIntervalDays, currentCorrectStreak: term.correctStreak)
            let service = try WordNoteV2ContentService(container: container)
            try service.recordLegacyFeedback(termID: term.id, expectedRevision: 0, mode: .chineseToEnglish, feedback: feedback, at: Support.now)
            XCTAssertEqual(term.revision, 1)
            XCTAssertEqual(term.masteryLevel, expected.masteryLevel)
            XCTAssertEqual(term.correctStreak, expected.correctStreak)
            XCTAssertEqual(term.reviewCount, old.reviewCount + 1)
            XCTAssertEqual(term.wrongCount, old.wrongCount + (expected.countsAsWrong ? 1 : 0))
            XCTAssertEqual(term.nextReviewAt, expected.nextReviewAt)
            XCTAssertEqual(term.counterSemanticsVersionRaw, "legacyMixed")
            let event = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV2.ReviewEventModel>()).first { $0.reviewedAt == Support.now })
            XCTAssertEqual(event.mode, .chineseToEnglish)
            XCTAssertEqual(event.feedback, feedback)
            XCTAssertEqual(event.previousNextReviewAt, old.nextReviewAt)
            XCTAssertEqual(event.previousMasteryLevelRaw, old.masteryLevelRaw)
        }
    }

    func testStaleFeedbackAndFailedSaveDoNotChangeTermOrHistory() throws {
        let container = try Support.container()
        let term = try Support.term("quick", in: container)
        let before = try Support.snapshot(container)
        let service = try WordNoteV2ContentService(container: container)
        XCTAssertThrowsError(try service.recordLegacyFeedback(termID: term.id, expectedRevision: 1, mode: .englishToChinese, feedback: .again))
        let failing = try WordNoteV2ContentService(container: container, save: { _ in throw Support.Failure.save })
        XCTAssertThrowsError(try failing.recordLegacyFeedback(termID: term.id, expectedRevision: 0, mode: .englishToChinese, feedback: .again))
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testPostponeTouchesRevisionButDoesNotRecordAnAnswer() throws {
        let container = try Support.container()
        let term = try Support.term("quick", in: container)
        let before = try Support.snapshot(container)
        let service = try WordNoteV2ContentService(container: container)
        try service.postponeLegacyReview(termID: term.id, expectedRevision: 0, from: Support.now)
        XCTAssertEqual(term.revision, 1)
        XCTAssertEqual(term.nextReviewAt, Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Support.now)))
        XCTAssertEqual(try Support.snapshot(container).content.reviewEvents, before.content.reviewEvents)
        XCTAssertThrowsError(try service.postponeLegacyReview(termID: term.id, expectedRevision: 0))
    }

    func testCounterLimitsAndRestoreGateRollbackReviewWrites() throws {
        let container = try Support.container()
        let term = try Support.term("quick", in: container)
        term.reviewCount = 1_000_000_000
        try container.mainContext.save()
        let before = try Support.snapshot(container)
        let service = try WordNoteV2ContentService(container: container)
        XCTAssertThrowsError(try service.recordLegacyFeedback(termID: term.id, expectedRevision: 0, mode: .englishToChinese, feedback: .good))
        XCTAssertEqual(try Support.snapshot(container), before)
        let ticket = try WordNoteWriteGate.beginRestore(container.mainContext)
        XCTAssertThrowsError(try service.postponeLegacyReview(termID: term.id, expectedRevision: 0))
        try WordNoteWriteGate.endRestore(container.mainContext, ticket: ticket)
    }

    func testV1AndV2QueuesHaveIdenticalLegacyOrdering() throws {
        let container = try Support.container()
        let before = try Support.snapshot(container)
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let old = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        try before.content.populateEmptyStore(old.mainContext)
        let terms = try container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV2.TermModel>())
        let oldTerms = try old.mainContext.fetch(FetchDescriptor<TermModel>())
        for scope in ReviewQueueScope.allCases {
            let oldIDs = ReviewQueuePolicy().terms(from: oldTerms, scope: scope, asOf: Support.now).map(\.id)
            let newIDs = ReviewQueuePolicy().terms(from: terms, scope: scope, asOf: Support.now).map(\.id)
            // Tied rows have no legacy tie-breaker; compare the sets within that unchanged policy.
            XCTAssertEqual(Set(oldIDs), Set(newIDs))
            XCTAssertEqual(oldIDs.first, newIDs.first)
        }
    }
}
