import XCTest
@testable import WordNoteCore

final class VocabularySelectionTests: XCTestCase {
    func testInitialSelectionAndStableFocusAfterSorting() {
        let a = UUID(), b = UUID(), c = UUID()
        var state = VocabularySelection()
        state.reconcile([a, b, c])
        XCTAssertEqual(state.focusedID, a)
        state.focusedID = b
        state.setSelected(true, id: a)
        state.reconcile([c, a, b])
        XCTAssertEqual(state.focusedID, b)
        XCTAssertEqual(state.batchIDs, [a])
    }

    func testScopeChangeClearsBatchEvenWhenVisibleIDsAreUnchanged() {
        let a = UUID(), b = UUID()
        var state = VocabularySelection()
        state.reconcile([a, b])
        state.focusedID = b
        state.toggleAll()
        state.reconcile([a, b], scopeChanged: true)
        XCTAssertEqual(state.focusedID, b)
        XCTAssertTrue(state.batchIDs.isEmpty)
    }

    func testDeletedFocusMovesToNearestSurvivingPosition() {
        let a = UUID(), b = UUID(), c = UUID()
        var state = VocabularySelection()
        state.reconcile([a, b, c])
        state.focusedID = b
        state.setSelected(true, id: b)
        state.reconcile([a, c])
        XCTAssertEqual(state.focusedID, c)
        XCTAssertTrue(state.batchIDs.isEmpty)
        state.reconcile([a])
        XCTAssertEqual(state.focusedID, a)
        state.reconcile([])
        XCTAssertNil(state.focusedID)
    }

    func testNewScopeChoosesFirstResultWhenFocusDisappears() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var state = VocabularySelection()
        state.reconcile([a, b, c])
        state.focusedID = c
        state.reconcile([d, a], scopeChanged: true)
        XCTAssertEqual(state.focusedID, d)
    }

    func testSelectAllIsVisibleOnlyAndSecondActivationClears() {
        let a = UUID(), b = UUID(), hidden = UUID()
        var state = VocabularySelection()
        state.reconcile([a, b])
        state.setSelected(true, id: hidden)
        XCTAssertTrue(state.batchIDs.isEmpty)
        state.setSelected(true, id: a)
        state.toggleAll()
        XCTAssertEqual(state.batchIDs, [a, b])
        state.toggleAll()
        XCTAssertTrue(state.batchIDs.isEmpty)
        state.reconcile([])
        state.toggleAll()
        XCTAssertTrue(state.batchIDs.isEmpty)
    }

    func testRefreshPrunesHiddenBatchWithoutDroppingVisibleSelections() {
        let a = UUID(), b = UUID()
        var state = VocabularySelection()
        state.reconcile([a, b])
        state.toggleAll()
        state.reconcile([b])
        XCTAssertEqual(state.batchIDs, [b])
        state.clearBatch()
        XCTAssertTrue(state.batchIDs.isEmpty)
        XCTAssertEqual(state.focusedID, b)
    }
}
