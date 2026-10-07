import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteEditProtectionTests: XCTestCase {
    private enum Failure: Error { case save }
    private final class WeakDraft {
        weak var value: WordNoteEditDraft<String>?
        init(_ value: WordNoteEditDraft<String>?) { self.value = value }
    }

    func testCleanTransitionRunsWithoutPrompt() {
        let protection = WordNoteEditProtection()
        var called = false
        XCTAssertTrue(protection.request { called = true })
        XCTAssertTrue(called)
        XCTAssertFalse(protection.isPresented)
    }

    func testCancelPreservesDraftAndDestinationUntilSheetDismissal() {
        let protection = WordNoteEditProtection()
        var destination = "original"
        var focusRestored = false
        protection.didCancel = { focusRestored = true }
        register(protection)
        protection.request(proceed: { destination = "new" })
        protection.resolve(.cancel)
        XCTAssertTrue(protection.hasUnsavedChanges)
        XCTAssertFalse(focusRestored)
        protection.completeTransition()
        XCTAssertTrue(focusRestored)
        XCTAssertEqual(destination, "original")
        XCTAssertFalse(protection.hasPendingTransition)
    }

    func testSaveRunsOnceAndDefersNavigationUntilDismissed() {
        let protection = WordNoteEditProtection()
        var saves = 0
        var moved = false
        register(protection, save: { saves += 1 })
        protection.request { moved = true }
        protection.resolve(.save)
        XCTAssertEqual(saves, 1)
        XCTAssertFalse(moved)
        XCTAssertFalse(protection.hasUnsavedChanges)
        protection.completeTransition()
        protection.completeTransition()
        XCTAssertTrue(moved)
        XCTAssertEqual(saves, 1)
    }

    func testSaveFailureRetainsPromptDraftAndPendingDestination() {
        let protection = WordNoteEditProtection()
        var fail = true
        var moved = false
        register(protection, save: { if fail { throw Failure.save } })
        protection.request { moved = true }
        protection.resolve(.save)
        XCTAssertTrue(protection.isPresented)
        XCTAssertNotNil(protection.errorMessage)
        XCTAssertTrue(protection.hasUnsavedChanges)
        protection.completeTransition()
        XCTAssertFalse(moved)
        fail = false
        protection.resolve(.save)
        protection.completeTransition()
        XCTAssertTrue(moved)
    }

    func testDiscardAllDraftsWithoutSaving() {
        let protection = WordNoteEditProtection()
        var discarded = 0
        for _ in 0..<3 {
            register(protection, save: { XCTFail("Must not save") }, discard: { discarded += 1 })
        }
        protection.request {}
        protection.resolve(.discard)
        XCTAssertEqual(discarded, 3)
        XCTAssertFalse(protection.hasUnsavedChanges)
        protection.completeTransition()
    }

    func testSecondRequestCannotReplacePendingNavigationEvenDuringDismissal() {
        let protection = WordNoteEditProtection()
        var destination = "original"
        register(protection)
        XCTAssertTrue(protection.request { destination = "first" })
        XCTAssertFalse(protection.request { destination = "second" })
        protection.resolve(.discard)
        XCTAssertFalse(protection.request { destination = "third" })
        protection.completeTransition()
        XCTAssertEqual(destination, "first")
    }

    func testUpdatingSameDraftUsesLatestValueAndReturningToBaselineClearsIt() {
        let protection = WordNoteEditProtection()
        let id = UUID()
        var saved = ""
        register(protection, id: id, save: { saved = "old" })
        register(protection, id: id, save: { saved = "new" })
        XCTAssertEqual(protection.drafts.count, 1)
        protection.request {}
        protection.resolve(.save)
        protection.completeTransition()
        XCTAssertEqual(saved, "new")
        let draft = WordNoteEditDraft("original")
        track(protection, id: id, draft: draft)
        draft.value = "edited"
        XCTAssertTrue(protection.hasUnsavedChanges)
        draft.value = "original"
        XCTAssertFalse(protection.hasUnsavedChanges)
    }

    func testPartialSaveFailureDoesNotRepeatCompletedSavesOrDropRemainingDrafts() {
        let protection = WordNoteEditProtection()
        var firstSaves = 0
        var secondSaves = 0
        var fail = true
        register(protection, save: { firstSaves += 1 })
        register(protection, save: { secondSaves += 1; if fail { throw Failure.save } })
        register(protection)
        protection.request {}
        protection.resolve(.save)
        XCTAssertEqual(firstSaves, 1)
        XCTAssertEqual(protection.drafts.count, 2)
        fail = false
        protection.resolve(.save)
        XCTAssertEqual(firstSaves, 1)
        XCTAssertEqual(secondSaves, 2)
        XCTAssertFalse(protection.hasUnsavedChanges)
    }

    func testResolveWithoutPendingDecisionIsNoOp() {
        let protection = WordNoteEditProtection()
        register(protection, save: { XCTFail("No transition") })
        protection.resolve(.save)
        protection.completeTransition()
        XCTAssertTrue(protection.hasUnsavedChanges)
    }

    func testLastKeystrokeIsReadWithoutReregisteringOrWaitingForViewUpdate() {
        let protection = WordNoteEditProtection()
        let draft = WordNoteEditDraft("original")
        var persisted = ""
        track(protection, draft: draft, save: { persisted = draft.value })
        XCTAssertFalse(protection.hasUnsavedChanges)
        draft.value = "last keystroke"
        protection.request {}
        XCTAssertTrue(protection.isPresented)
        XCTAssertEqual(protection.drafts.first?.preview, "last keystroke")
        protection.resolve(.save)
        protection.completeTransition()
        XCTAssertEqual(persisted, "last keystroke")
        XCTAssertFalse(protection.hasUnsavedChanges)
        draft.value = "next edit"
        XCTAssertTrue(protection.hasUnsavedChanges)
    }

    func testDetachedDirtyDraftRetainsValuesAndCanBeDiscarded() {
        let protection = WordNoteEditProtection()
        let id = UUID()
        var draft: WordNoteEditDraft<String>? = WordNoteEditDraft("baseline")
        let retained = WeakDraft(draft)
        track(protection, id: id, draft: draft!)
        draft?.value = "unsaved text"
        protection.detach(id)
        draft = nil
        XCTAssertNotNil(retained.value)
        XCTAssertEqual(protection.drafts.first?.preview, "unsaved text")
        protection.request {}
        protection.resolve(.discard)
        protection.completeTransition()
        XCTAssertNil(retained.value)
        XCTAssertFalse(protection.hasUnsavedChanges)
    }

    func testDetachingCleanDraftReleasesIt() {
        let protection = WordNoteEditProtection()
        let id = UUID()
        var draft: WordNoteEditDraft<String>? = WordNoteEditDraft("baseline")
        let retained = WeakDraft(draft)
        track(protection, id: id, draft: draft!)
        protection.detach(id)
        draft = nil
        XCTAssertNil(retained.value)
    }

    func testUnclearedDraftCannotSilentlyNavigateAfterSuccessfulSaveCallback() {
        let protection = WordNoteEditProtection()
        protection.track(id: UUID(), title: "Buggy editor", preview: { "text" }, isDirty: { true }, save: {}, discard: {})
        var moved = false
        protection.request { moved = true }
        protection.resolve(.save)
        protection.completeTransition()
        XCTAssertTrue(protection.isPresented)
        XCTAssertNotNil(protection.errorMessage)
        XCTAssertFalse(moved)
    }

    private func register(
        _ protection: WordNoteEditProtection, id: UUID = UUID(),
        save: @escaping () throws -> Void = {}, discard: @escaping () -> Void = {}
    ) {
        let draft = WordNoteEditDraft("original")
        draft.value = "Detached draft"
        track(protection, id: id, draft: draft, save: save, discard: discard)
    }

    private func track(
        _ protection: WordNoteEditProtection, id: UUID = UUID(), draft: WordNoteEditDraft<String>,
        save: @escaping () throws -> Void = {}, discard: @escaping () -> Void = {}
    ) {
        protection.track(id: id, title: "Term", preview: { draft.value }, isDirty: { draft.isDirty },
                         save: { try save(); draft.baseline = draft.value },
                         discard: { discard(); draft.value = draft.baseline })
    }
}
