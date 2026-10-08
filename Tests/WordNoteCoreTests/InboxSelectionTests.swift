import XCTest
@testable import WordNoteCore

final class InboxSelectionTests: XCTestCase {
    func testPartialHandlingKeepsFocusAndPrunesOnlyIneligibleBatchIDs() {
        let a = UUID(), b = UUID()
        var selection = InboxSelection()
        selection.reconcile(active: [a, b], handled: [], confirmable: [a, b])
        selection.toggleAll()
        selection.reconcile(active: [a, b], handled: [], confirmable: [a])
        XCTAssertEqual(selection.focusedID, a)
        XCTAssertEqual(selection.batchIDs, [a])
    }

    func testFullHandlingChoosesOldNextNeighborInsteadOfNewTopOrExpandedHandledRow() {
        let a = UUID(), b = UUID(), c = UUID(), newcomer = UUID()
        var selection = InboxSelection()
        selection.reconcile(active: [a, b, c], handled: [], confirmable: [a, b, c])
        selection.focusedID = b
        selection.reconcile(active: [newcomer, a, c], handled: [b], confirmable: [newcomer, a, c])
        XCTAssertEqual(selection.focusedID, c)
    }

    func testHandlingLastRowChoosesPreviousSurvivorThenFallsBackWhenNoneRemain() {
        let a = UUID(), b = UUID(), c = UUID(), newcomer = UUID()
        var selection = InboxSelection()
        selection.reconcile(active: [a, b, c], handled: [], confirmable: [a, b, c])
        selection.focusedID = c
        selection.reconcile(active: [newcomer, a], handled: [], confirmable: [a])
        XCTAssertEqual(selection.focusedID, a)
        selection.reconcile(active: [newcomer], handled: [], confirmable: [])
        XCTAssertEqual(selection.focusedID, newcomer)
        selection.reconcile(active: [], handled: [], confirmable: [])
        XCTAssertNil(selection.focusedID)
    }

    func testUndoReturningAnOlderItemDoesNotStealFocus() {
        let a = UUID(), b = UUID()
        var selection = InboxSelection()
        selection.reconcile(active: [b], handled: [], confirmable: [b])
        selection.reconcile(active: [a, b], handled: [], confirmable: [a, b])
        XCTAssertEqual(selection.focusedID, b)
    }

    func testFilterChangeClearsBatchEvenWhenSameRecordsStayVisible() {
        let a = UUID(), b = UUID()
        var selection = InboxSelection()
        selection.reconcile(active: [a, b], handled: [], confirmable: [a, b])
        selection.focusedID = b
        selection.toggleAll()
        selection.reconcile(active: [a, b], handled: [], confirmable: [a, b], scopeChanged: true)
        XCTAssertEqual(selection.focusedID, b)
        XCTAssertTrue(selection.batchIDs.isEmpty)
        selection.reconcile(active: [a], handled: [], confirmable: [a], scopeChanged: true)
        XCTAssertEqual(selection.focusedID, a)
    }

    func testSelectAllOnlyUsesVisibleEligibleIDsAndSecondToggleClears() {
        let a = UUID(), draft = UUID(), handled = UUID(), hidden = UUID()
        var selection = InboxSelection()
        selection.reconcile(active: [a, draft], handled: [handled], confirmable: [a, handled, hidden])
        for id in [draft, handled, hidden] { selection.setSelected(true, id: id) }
        XCTAssertTrue(selection.batchIDs.isEmpty)
        selection.toggleAll()
        XCTAssertEqual(selection.batchIDs, [a])
        selection.toggleAll()
        XCTAssertTrue(selection.batchIDs.isEmpty)
        selection.setSelected(true, id: a)
        selection.reconcile(active: [draft], handled: [a, handled], confirmable: [])
        XCTAssertTrue(selection.batchIDs.isEmpty)
    }

    func testCollapsingHandledClearsHiddenFocusWithoutAffectingBatch() {
        let a = UUID(), handled = UUID()
        var selection = InboxSelection()
        selection.reconcile(active: [a], handled: [handled], confirmable: [a])
        selection.focusedID = handled
        selection.setSelected(true, id: a)
        selection.reconcile(active: [a], handled: [], confirmable: [a])
        XCTAssertEqual(selection.focusedID, a)
        XCTAssertEqual(selection.batchIDs, [a])
    }
}

@MainActor
final class InboxCandidateSelectionTests: XCTestCase {
    func testRecommendedCandidatesInitializeOnceWhenFirstPendingArrive() {
        var selection = InboxCandidateSelection()
        selection.reconcile([])
        let record = InboxTestValues.record()
        let recommended = InboxTestValues.candidate(record: record), low = InboxTestValues.candidate(record: record)
        let unnecessary = InboxTestValues.candidate(record: record)
        low.importance = .low
        unnecessary.needToLearn = false
        let values = [recommended, low, unnecessary].map(WordNoteSnapshotPayload.Candidate.init)
        selection.reconcile(values)
        XCTAssertEqual(selection.selectedIDs, [recommended.id])
        selection.select([])
        selection.reconcile(values)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
    }

    func testLaterCandidatesDoNotEnterSelectionAndHandledCandidatesArePruned() {
        let record = InboxTestValues.record()
        let first = InboxTestValues.candidate(record: record), next = InboxTestValues.candidate(record: record)
        var selection = InboxCandidateSelection()
        selection.reconcile([.init(first)])
        selection.reconcile([first, next].map(WordNoteSnapshotPayload.Candidate.init))
        XCTAssertEqual(selection.selectedIDs, [first.id])
        first.status = .ignored
        selection.reconcile([first, next].map(WordNoteSnapshotPayload.Candidate.init))
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertEqual(selection.pendingIDs, [next.id])
    }

    func testToggleAllAllowsLowImportanceButNeverHandledOrUnknownIDs() {
        let record = InboxTestValues.record()
        let low = InboxTestValues.candidate(record: record), handled = InboxTestValues.candidate(record: record)
        low.importance = .low
        handled.status = .saved
        var selection = InboxCandidateSelection()
        selection.reconcile([low, handled].map(WordNoteSnapshotPayload.Candidate.init))
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        selection.select([handled.id, UUID()])
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        selection.toggleAll()
        XCTAssertEqual(selection.selectedIDs, [low.id])
        selection.toggleAll()
        XCTAssertTrue(selection.selectedIDs.isEmpty)
    }
}
