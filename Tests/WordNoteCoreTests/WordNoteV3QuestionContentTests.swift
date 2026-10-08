import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3QuestionContentTests: XCTestCase {
    private typealias Support = V3QuestionTestSupport

    func testChineseFrontHidesEnglishAndDoesNotCarryExamplesOrAnswerFields() throws {
        let container = try Support.container()
        var payload = try V3SessionTestSupport.snapshot(container)
        payload.cards[0].mode = .chineseToEnglish
        let front = try ReviewQuestionContent.front(card: payload.cards[0], term: payload.content.content.terms[0])
        XCTAssertEqual(front.prompt, "____：快速的；敏捷的")
        XCTAssertTrue(front.allowsTypedAnswer)
        XCTAssertEqual(Set(Mirror(reflecting: front).children.compactMap(\.label)), ["cardID", "mode", "prompt"])
        let back = try ReviewQuestionContent.back(card: payload.cards[0], term: payload.content.content.terms[0], typedAnswer: "  QUICK ")
        XCTAssertEqual(back.answer, "quick")
        XCTAssertEqual(back.typedAnswer, "  QUICK ")
        XCTAssertEqual(back.assessment, .matchesSavedAnswer)
        XCTAssertNotNil(back.example)
    }

    func testFormalBackRequiresRevealedSnapshotAndReadingDoesNotWriteEvents() throws {
        let container = try Support.container()
        let review = try WordNoteV3ReviewService(container: container)
        let (lease, source) = try V3SessionTestSupport.startPresented(review)
        XCTAssertEqual(try review.questionFront(sessionID: lease.sessionID).prompt, "quick")
        XCTAssertThrowsError(try review.revealedQuestion(lease: lease)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .answerNotRevealed)
        }
        _ = try review.revealAnswer(source, lease: lease, at: Support.now)
        let before = try V3SessionTestSupport.snapshot(container)
        let back = try review.revealedQuestion(lease: lease, typedAnswer: "fast")
        XCTAssertEqual(back.assessment, .needsSelfAssessment)
        XCTAssertEqual(try V3SessionTestSupport.snapshot(container), before)
        XCTAssertTrue(before.eventStates.isEmpty)
    }

    func testAnswerChangesAndLeaseReleaseRevokeBackAccess() throws {
        let container = try Support.container()
        let review = try WordNoteV3ReviewService(container: container)
        let (lease, source) = try V3SessionTestSupport.startPresented(review)
        _ = try review.revealAnswer(source, lease: lease, at: Support.now)
        let term = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()).first)
        term.chineseMeaning = "新釋義"
        try container.mainContext.save()
        XCTAssertThrowsError(try review.revealedQuestion(lease: lease))
        _ = try review.revealAnswer(review.currentAnswerSnapshot(sessionID: lease.sessionID), lease: lease, at: Support.now)
        XCTAssertNoThrow(try review.revealedQuestion(lease: lease))
        review.releaseLease(lease)
        XCTAssertThrowsError(try review.revealedQuestion(lease: lease))
    }

    func testClozeFrontAndBackKeepOriginalAndSelectedAnswerSeparate() throws {
        let container = try Support.container()
        let content = try WordNoteV3ContentService(container: container)
        _ = try Support.create(content, container: container)
        let review = try WordNoteV3ReviewService(container: container)
        let session = try review.startSession(scope: V3SessionTestSupport.scope(newCards: true, mode: .contextCloze), at: Support.now)
        let lease = try review.acquireLease(sessionID: session.session.id, ownerID: UUID())
        let shown = try XCTUnwrap(review.presentNextCard(lease: lease, expectedRevision: session.session.revision, at: Support.now))
        XCTAssertEqual(try review.questionFront(sessionID: lease.sessionID).prompt, "A ____ response needs ____ thinking.")
        _ = try review.revealAnswer(shown, lease: lease, at: Support.now)
        let back = try review.revealedQuestion(lease: lease, typedAnswer: "fast")
        XCTAssertEqual(back.answer, "quick")
        XCTAssertEqual(back.originalText, "A quick response needs quick thinking.")
        XCTAssertEqual(back.example, "A quick AI example is not an original source.")
        XCTAssertEqual(back.assessment, .needsSelfAssessment)
    }

    func testUnusableChangedPromptDoesNotChargeQuotaOrAdvanceCursor() throws {
        let container = try V3SessionTestSupport.container(count: 1, newCards: true)
        let review = try WordNoteV3ReviewService(container: container)
        let session = try review.startSession(scope: V3SessionTestSupport.scope(newCards: true), at: Support.now)
        let lease = try review.acquireLease(sessionID: session.session.id, ownerID: UUID())
        let term = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()).first)
        term.chineseMeaning = nil
        try container.mainContext.save()
        let before = try V3SessionTestSupport.snapshot(container)
        XCTAssertThrowsError(try review.presentNextCard(lease: lease, expectedRevision: session.session.revision, at: Support.now))
        XCTAssertEqual(try V3SessionTestSupport.snapshot(container), before)
        XCTAssertNil(before.cards[0].schedule.introducedAt)
    }

    func testSelectionAndStatisticsSharePromptEligibilityAndSeparateSuspendedCards() throws {
        let container = try Support.container()
        var payload = try V3SessionTestSupport.snapshot(container)
        payload.cards[0].mode = .chineseToEnglish
        payload.content.content.terms[0].chineseMeaning = "quick"
        try payload.validate()
        let scope = V3SessionTestSupport.scope(mode: .chineseToEnglish)
        XCTAssertTrue(try ReviewSessionSelection(payload: payload, scope: scope, target: 5, newCardLimit: 10, at: Support.now).cardIDs.isEmpty)
        var stats = try ReviewStatisticsBuilder(payload: payload).overview(studyTimeZoneID: Support.zone, at: Support.now)
        XCTAssertEqual(stats.workload.missingAnswerCards, 1)
        XCTAssertEqual(stats.workload.readyCards, 0)
        payload.cards[0].schedule.phase = .suspended
        payload.cards[0].schedule.nextReviewAt = nil
        stats = try ReviewStatisticsBuilder(payload: payload).overview(studyTimeZoneID: Support.zone, at: Support.now)
        XCTAssertEqual(stats.workload.suspendedCards, 1)
        XCTAssertEqual(stats.workload.missingAnswerCards, 0)
    }
}
