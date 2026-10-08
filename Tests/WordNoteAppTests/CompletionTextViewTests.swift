import AppKit
import XCTest
@testable import WordNote

@MainActor
final class CompletionTextViewTests: XCTestCase {
    func testCommandReturnSubmitsCommittedTextOnceAndUpdatesBindingFirst() throws {
        let view = CompletionTextView()
        view.string = "quick"
        var actions: [String] = []
        view.bindingUpdateHandler = { actions.append($0) }
        view.commandSubmitHandler = { actions.append("submit") }
        XCTAssertTrue(view.performKeyEquivalent(with: try event(code: 36)))
        XCTAssertEqual(actions, ["quick", "submit"])
    }

    func testKeypadCommandEnterAndDirectKeyDownUseSameSubmissionPath() throws {
        let view = CompletionTextView()
        var count = 0
        view.commandSubmitHandler = { count += 1 }
        XCTAssertTrue(view.performKeyEquivalent(with: try event(code: 76)))
        view.keyDown(with: try event(code: 36))
        XCTAssertEqual(count, 2)
    }

    func testOtherModifiersAndKeysAreNotCommandSubmit() throws {
        let view = CompletionTextView()
        var count = 0
        view.commandSubmitHandler = { count += 1 }
        for flags: NSEvent.ModifierFlags in [[], [.command, .shift], [.command, .option], [.control]] {
            _ = view.performKeyEquivalent(with: try event(code: 36, flags: flags))
        }
        _ = view.performKeyEquivalent(with: try event(code: 0))
        XCTAssertEqual(count, 0)
    }

    func testCapsLockDoesNotChangeCommandReturnMeaning() throws {
        let view = CompletionTextView()
        var count = 0
        view.commandSubmitHandler = { count += 1 }
        XCTAssertTrue(view.performKeyEquivalent(with: try event(code: 36, flags: [.command, .capsLock])))
        XCTAssertEqual(count, 1)
    }

    func testMarkedCommandReturnIsConsumedWithoutSubmitting() throws {
        let view = CompletionTextView()
        view.setMarkedText("qui", selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        var count = 0
        view.commandSubmitHandler = { count += 1 }
        XCTAssertTrue(view.performKeyEquivalent(with: try event(code: 36)))
        XCTAssertEqual(count, 0)
        XCTAssertEqual(view.string, "qui")
    }

    func testEditorDoesNotStealCommandReturnFromAnotherFirstResponder() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: true)
        let view = CompletionTextView()
        window.contentView = view
        var count = 0
        view.commandSubmitHandler = { count += 1 }
        window.makeFirstResponder(nil)
        XCTAssertFalse(view.performKeyEquivalent(with: try event(code: 36)))
        XCTAssertEqual(count, 0)
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertTrue(view.performKeyEquivalent(with: try event(code: 36)))
        XCTAssertEqual(count, 1)
    }

    func testSingleLineReturnStillSubmitsWithoutCommand() {
        let view = CompletionTextView()
        view.isMultiline = false
        var regular = 0, command = 0
        view.submitHandler = { regular += 1 }
        view.commandSubmitHandler = { command += 1 }
        view.doCommand(by: #selector(NSTextView.insertNewline(_:)))
        XCTAssertEqual(regular, 1)
        XCTAssertEqual(command, 0)
    }

    func testMultilineReturnInsertsNewlineWithoutSubmitting() {
        let view = CompletionTextView()
        view.string = "quick"
        view.setSelectedRange(NSRange(location: 5, length: 0))
        var count = 0
        view.commandSubmitHandler = { count += 1 }
        view.doCommand(by: #selector(NSTextView.insertNewline(_:)))
        XCTAssertEqual(view.string, "quick\n")
        XCTAssertEqual(count, 0)
    }

    func testCommandReturnDoesNotAcceptGhostCompletionButTabDoes() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: true)
        let view = CompletionTextView()
        window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view))
        view.vocabulary = ["quick"]
        view.string = "qui"
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.refreshCompletion()
        var submitted: [String] = []
        view.commandSubmitHandler = { submitted.append(view.string) }
        defer { view.commandSubmitHandler = nil }
        XCTAssertTrue(view.performKeyEquivalent(with: try event(code: 36)))
        XCTAssertEqual(submitted, ["qui"])
        XCTAssertEqual(view.string, "qui")
        view.doCommand(by: #selector(NSTextView.insertTab(_:)))
        XCTAssertEqual(view.string, "quick")
        XCTAssertEqual(submitted, ["qui"])
    }

    func testSingleLineReturnDuringCompositionDoesNotSubmit() {
        let view = CompletionTextView()
        view.isMultiline = false
        view.setMarkedText("qui", selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        var count = 0
        view.submitHandler = { count += 1 }
        view.doCommand(by: #selector(NSTextView.insertNewline(_:)))
        XCTAssertEqual(count, 0)
    }

    func testCommandReturnWithoutHandlerLeavesExistingWindowShortcutAvailable() throws {
        let view = CompletionTextView()
        view.string = "quick"
        XCTAssertFalse(view.performKeyEquivalent(with: try event(code: 36)))
        XCTAssertEqual(view.string, "quick")
    }

    private func event(code: UInt16, flags: NSEvent.ModifierFlags = [.command]) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                      isARepeat: false, keyCode: code))
    }
}
