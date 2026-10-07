import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteQuitProtectionTests: XCTestCase {
    func testCleanWindowsAllowQuitWithoutPrompt() {
        let quit = WordNoteQuitProtection()
        let window = WordNoteEditProtection()
        var allowed: Bool?
        XCTAssertTrue(quit.request(protections: { [window] }, completion: { allowed = $0 }))
        XCTAssertEqual(allowed, true)
        XCTAssertFalse(quit.isActive)
    }

    func testAllWindowsMustResolveBeforeQuitAndRepeatedQuitDoesNotReplaceCallback() {
        let quit = WordNoteQuitProtection()
        let first = dirtyWindow()
        let second = dirtyWindow()
        var allowed: Bool?
        var activations = 0
        quit.request(protections: { [first, second] }, activate: { _ in activations += 1 }, completion: { allowed = $0 })
        XCTAssertTrue(first.isPresented)
        XCTAssertFalse(second.isPresented)
        XCTAssertFalse(quit.request(protections: { [] }, completion: { _ in XCTFail("Replaced quit") }))
        first.resolve(.save)
        first.completeTransition()
        XCTAssertTrue(second.isPresented)
        XCTAssertNil(allowed)
        second.resolve(.discard)
        second.completeTransition()
        XCTAssertEqual(allowed, true)
        XCTAssertEqual(activations, 2)
        XCTAssertFalse(quit.isActive)
    }

    func testCancelInSecondWindowKeepsItsDraftAndDoesNotUndoFirstSave() {
        let quit = WordNoteQuitProtection()
        let first = dirtyWindow()
        let second = dirtyWindow()
        var allowed: Bool?
        quit.request(protections: { [first, second] }, completion: { allowed = $0 })
        first.resolve(.save)
        first.completeTransition()
        second.resolve(.cancel)
        second.completeTransition()
        XCTAssertEqual(allowed, false)
        XCTAssertFalse(first.hasUnsavedChanges)
        XCTAssertTrue(second.hasUnsavedChanges)
    }

    func testPendingNavigationCannotBeOverwrittenByQuit() {
        let quit = WordNoteQuitProtection()
        let window = dirtyWindow()
        var navigated = false
        window.request { navigated = true }
        XCTAssertFalse(quit.request(protections: { [window] }, completion: { _ in XCTFail("Must not replace navigation") }))
        window.resolve(.discard)
        window.completeTransition()
        XCTAssertTrue(navigated)
    }

    func testWindowOpenedDuringQuitIsIncludedBeforeFinalReply() {
        let quit = WordNoteQuitProtection()
        let first = dirtyWindow()
        var windows = [first]
        var allowed: Bool?
        quit.request(protections: { windows }, completion: { allowed = $0 })
        let second = dirtyWindow()
        windows.append(second)
        first.resolve(.discard)
        first.completeTransition()
        XCTAssertTrue(second.isPresented)
        XCTAssertNil(allowed)
        second.resolve(.save)
        second.completeTransition()
        XCTAssertEqual(allowed, true)
    }

    func testSaveFailureBlocksQuitUntilCancel() {
        let quit = WordNoteQuitProtection()
        let window = WordNoteEditProtection()
        let draft = WordNoteEditDraft("original")
        draft.value = "edited"
        window.track(id: UUID(), title: "Term", preview: { draft.value }, isDirty: { draft.isDirty },
                     save: { throw WordNoteV2ContentError.missingEntity }, discard: { draft.value = draft.baseline })
        var allowed: Bool?
        quit.request(protections: { [window] }, completion: { allowed = $0 })
        window.resolve(.save)
        window.completeTransition()
        XCTAssertTrue(quit.isActive)
        XCTAssertTrue(window.isPresented)
        XCTAssertNil(allowed)
        window.resolve(.cancel)
        window.completeTransition()
        XCTAssertEqual(allowed, false)
        XCTAssertTrue(draft.isDirty)
    }

    private func dirtyWindow() -> WordNoteEditProtection {
        let window = WordNoteEditProtection()
        let draft = WordNoteEditDraft("original")
        draft.value = "edited"
        window.track(id: UUID(), title: "Term", preview: { draft.value }, isDirty: { draft.isDirty },
                     save: { draft.baseline = draft.value }, discard: { draft.value = draft.baseline })
        return window
    }
}
