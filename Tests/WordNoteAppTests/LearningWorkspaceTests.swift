import XCTest
import WordNoteCore
@testable import WordNote

@MainActor
final class LearningWorkspaceTests: XCTestCase {
    func testLinkedTermKeepsFiltersSelectionAndScrollThenBackRestoresThem() {
        let state = LearningWorkspace()
        state.destination = .vocabulary
        let visible = [UUID(), UUID()], target = UUID(), card = UUID()
        state.vocabulary.query.text = "query"
        state.vocabulary.query.courseID = UUID()
        state.vocabulary.cards = .init(mode: .chineseToEnglish, mastery: .vague)
        state.vocabulary.selection.reconcile(visible)
        state.vocabulary.selection.focusedID = visible[1]
        state.vocabulary.selection.setSelected(true, id: visible[0])
        state.vocabulary.scrollID = visible[1]
        let original = state.vocabulary
        state.open(.term(target, cardID: card))
        XCTAssertEqual(state.vocabulary.openedTermID, target)
        XCTAssertEqual(state.vocabulary.openedCardID, card)
        XCTAssertEqual(state.vocabulary.query, original.query)
        XCTAssertEqual(state.vocabulary.selection, original.selection)
        state.vocabulary.query.text = "changed while reading"
        state.back()
        XCTAssertEqual(state.vocabulary, original)
        XCTAssertEqual(state.destination, .vocabulary)
        XCTAssertFalse(state.canGoBack)
    }

    func testCourseInboxRouteDoesNotLeakOldFiltersAndBackRestoresInboxState() {
        let state = LearningWorkspace(), course = UUID(), record = UUID()
        state.destination = .courses
        state.courseID = course
        state.courseTab = .inbox
        state.courseMode = .chineseToEnglish
        state.courseCardState = .waiting
        state.courseScrollID = record
        state.inbox.query.text = "old query"
        state.inbox.query.source = .book
        state.inbox.query.status = .failed
        state.inbox.scrollID = record
        state.inbox.selection.reconcile(active: [record], handled: [], confirmable: [record])
        state.inbox.selection.toggleAll()
        let before = state.inbox
        state.open(.inbox(courseID: course))
        XCTAssertEqual(state.destination, .inbox)
        XCTAssertEqual(state.inbox.query.courseID, course)
        XCTAssertTrue(state.inbox.query.text.isEmpty)
        XCTAssertNil(state.inbox.query.source)
        XCTAssertEqual(state.inbox.query.status, .all)
        XCTAssertTrue(state.inbox.selection.batchIDs.isEmpty)
        XCTAssertNil(state.inbox.scrollID)
        state.back()
        XCTAssertEqual(state.inbox, before)
        XCTAssertEqual(state.destination, .courses)
        XCTAssertEqual(state.courseID, course)
        XCTAssertEqual(state.courseTab, .inbox)
        XCTAssertEqual(state.courseMode, .chineseToEnglish)
        XCTAssertEqual(state.courseCardState, .waiting)
        XCTAssertEqual(state.courseScrollID, record)
    }

    func testRecordPinDoesNotClearExistingSearchOrSubstituteAListNeighbor() {
        let state = LearningWorkspace(), first = UUID(), missing = UUID()
        state.inbox.query.text = "preserved"
        state.inbox.selection.reconcile(active: [first], handled: [], confirmable: [first])
        state.open(.record(missing))
        XCTAssertEqual(state.inbox.openedRecordID, missing)
        XCTAssertEqual(state.inbox.selection.focusedID, first)
        XCTAssertEqual(state.inbox.query.text, "preserved")
    }

    func testAllCardsRouteMatchesTheRequestedDirectionAndStateAndBackRestoresFilters() {
        let state = LearningWorkspace(), course = UUID()
        state.vocabulary.query.text = "old search"
        state.vocabulary.query.tag = "old tag"
        state.vocabulary.openedTermID = UUID()
        let before = state.vocabulary
        let cards = VocabularyCardQuery(mode: .chineseToEnglish, state: .waiting)
        state.open(.vocabulary(courseID: course, cards: cards))
        XCTAssertEqual(state.destination, .vocabulary)
        XCTAssertEqual(state.vocabulary.query.courseID, course)
        XCTAssertTrue(state.vocabulary.query.text.isEmpty)
        XCTAssertNil(state.vocabulary.query.tag)
        XCTAssertNil(state.vocabulary.openedTermID)
        XCTAssertEqual(state.vocabulary.cards, cards)
        state.back()
        XCTAssertEqual(state.vocabulary, before)
    }

    func testReviewRoutePreselectsOnlySetupAndContinueDoesNotReplaceIt() {
        let state = LearningWorkspace()
        let setup = ReviewSetupSelection(courseID: UUID(), mode: .contextCloze, queue: .weakTerms, includesNew: true)
        state.open(.review(setup))
        XCTAssertEqual(state.review, setup)
        state.open(.continueReview)
        XCTAssertEqual(state.review, setup)
        XCTAssertEqual(state.destination, .review)
        state.back()
        XCTAssertEqual(state.review, setup)
    }

    func testWindowStateAndHistoryAreIndependent() {
        let first = LearningWorkspace(), second = LearningWorkspace()
        first.vocabulary.query.text = "first"
        first.open(.term(UUID()))
        XCTAssertEqual(second.destination, .dashboard)
        XCTAssertFalse(second.canGoBack)
        XCTAssertTrue(second.vocabulary.query.text.isEmpty)
        second.open(.record(UUID()))
        XCTAssertEqual(first.destination, .vocabulary)
    }

    func testDirtyNavigationWaitsAndCancelLeavesCaptureContextUnchanged() {
        let state = LearningWorkspace(), protection = WordNoteEditProtection()
        var dirty = true, prepared = 0
        protection.track(id: UUID(), title: "Draft", preview: { "Draft" }, isDirty: { dirty },
                         save: { dirty = false }, discard: { dirty = false })
        XCTAssertTrue(state.open(.capture(courseID: UUID()), protection: protection) { prepared += 1 })
        XCTAssertEqual(prepared, 0)
        XCTAssertEqual(state.destination, .dashboard)
        XCTAssertFalse(state.canGoBack)
        XCTAssertFalse(state.open(.term(UUID()), protection: protection))
        protection.resolve(.cancel)
        protection.completeTransition()
        XCTAssertTrue(dirty)
        XCTAssertEqual(prepared, 0)
        XCTAssertFalse(state.canGoBack)
    }

    func testCaptureNavigationUpdatesCurrentCourseOnlyAfterDirtyTransition() throws {
        let suite = "LearningWorkspaceTests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = UUID(), next = UUID()
        let capture = CaptureContextController(preferences: preferences, availableCourseIDs: [first, next])
        try capture.updateDefaults(.init(courseID: first, sourceType: .book, intent: .englishToChinese))
        let defaults = capture.defaultContext
        let state = LearningWorkspace(), protection = WordNoteEditProtection()
        var dirty = true
        protection.track(id: UUID(), title: "Draft", preview: { "Draft" }, isDirty: { dirty },
                         save: { dirty = false }, discard: { dirty = false })
        state.open(.capture(courseID: next), protection: protection) { try capture.selectCourse(next) }
        XCTAssertEqual(capture.current.courseID, first)
        protection.resolve(.discard)
        XCTAssertEqual(capture.current.courseID, first)
        protection.completeTransition()
        XCTAssertEqual(capture.current.courseID, next)
        XCTAssertEqual(capture.defaultContext, defaults)
        XCTAssertEqual(capture.current.sourceType, defaults.sourceType)
        XCTAssertEqual(capture.current.intent, defaults.intent)
        XCTAssertEqual(state.destination, .quickAdd)
    }

    func testFailedPreparationDoesNotNavigateOrConsumeHistory() {
        let state = LearningWorkspace()
        state.open(.capture(courseID: UUID())) { throw CaptureContextError.missingCourse }
        XCTAssertEqual(state.destination, .dashboard)
        XCTAssertFalse(state.canGoBack)
        XCTAssertNotNil(state.errorMessage)
    }

    func testBackHonorsDirtyProtectionAndDoesNotPopOnCancel() {
        let state = LearningWorkspace(), protection = WordNoteEditProtection()
        state.open(.term(UUID()))
        var dirty = true
        protection.track(id: UUID(), title: "Draft", preview: { "Draft" }, isDirty: { dirty },
                         save: { dirty = false }, discard: { dirty = false })
        state.back(protection: protection)
        XCTAssertEqual(state.destination, .vocabulary)
        protection.resolve(.cancel)
        protection.completeTransition()
        XCTAssertTrue(state.canGoBack)
        state.back(protection: protection)
        protection.resolve(.save)
        protection.completeTransition()
        XCTAssertEqual(state.destination, .dashboard)
        XCTAssertFalse(state.canGoBack)
    }

    func testSidebarSwitchRetainsPerViewStateButStartsANewNavigationPath() {
        let state = LearningWorkspace()
        state.open(.term(UUID()))
        state.vocabulary.query.text = "saved filter"
        state.select(.courses, protection: nil)
        XCTAssertFalse(state.canGoBack)
        state.select(.vocabulary, protection: nil)
        XCTAssertEqual(state.vocabulary.query.text, "saved filter")
    }

    func testLongNavigationHistoryHasABoundedBackStack() {
        let state = LearningWorkspace()
        for _ in 0..<35 { state.open(.record(UUID())) }
        var count = 0
        while state.canGoBack { state.back(); count += 1 }
        XCTAssertEqual(count, 30)
    }
}
