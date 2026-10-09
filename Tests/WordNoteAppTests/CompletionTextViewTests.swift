import AppKit
import XCTest
@testable import WordNote

@MainActor
final class CompletionTextViewTests: XCTestCase {
    func testCommandReturnSubmitsCommittedTextOnceAndUpdatesBindingFirst() throws {
        let view = CompletionTextView()
        view.commandShortcutsEnabled = true
        view.string = "quick"
        var actions: [String] = []
        view.bindingUpdateHandler = { actions.append($0) }
        view.commandSubmitHandler = { actions.append("submit") }
        XCTAssertTrue(view.performKeyEquivalent(with: try event(code: 36)))
        XCTAssertEqual(actions, ["quick", "submit"])
    }

    func testKeypadCommandEnterAndDirectKeyDownUseSameSubmissionPath() throws {
        let view = CompletionTextView()
        view.commandShortcutsEnabled = true
        var count = 0
        view.commandSubmitHandler = { count += 1 }
        XCTAssertTrue(view.performKeyEquivalent(with: try event(code: 76)))
        view.keyDown(with: try event(code: 36))
        XCTAssertEqual(count, 2)
    }

    func testOtherModifiersAndKeysAreNotCommandSubmit() throws {
        let view = CompletionTextView()
        view.commandShortcutsEnabled = true
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
        view.commandShortcutsEnabled = true
        var count = 0
        view.commandSubmitHandler = { count += 1 }
        XCTAssertTrue(view.performKeyEquivalent(with: try event(code: 36, flags: [.command, .capsLock])))
        XCTAssertEqual(count, 1)
    }

    func testMarkedCommandReturnIsConsumedWithoutSubmitting() throws {
        let view = CompletionTextView()
        view.commandShortcutsEnabled = true
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
        view.commandShortcutsEnabled = true
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
        view.commandShortcutsEnabled = true
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
        view.commandShortcutsEnabled = true
        view.string = "quick"
        XCTAssertFalse(view.performKeyEquivalent(with: try event(code: 36)))
        XCTAssertEqual(view.string, "quick")
    }

    func testCommandSubmitIsOffByDefaultAndCanToggleWithoutRecreatingEditor() throws {
        let view = CompletionTextView()
        var calls = 0
        view.commandSubmitHandler = { calls += 1 }
        XCTAssertFalse(view.commandShortcutsEnabled)
        XCTAssertFalse(view.performKeyEquivalent(with: try event(code: 36)))
        view.keyDown(with: try event(code: 36))
        XCTAssertEqual(calls, 0)
        view.commandShortcutsEnabled = true
        XCTAssertTrue(view.performKeyEquivalent(with: try event(code: 36)))
        XCTAssertEqual(calls, 1)
        view.commandShortcutsEnabled = false
        XCTAssertFalse(view.performKeyEquivalent(with: try event(code: 76)))
        XCTAssertEqual(calls, 1)
    }

    func testTabCompletionAndEscapeKeepWorkingWithCommandsOff() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: true)
        let view = CompletionTextView()
        window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertFalse(view.commandShortcutsEnabled)
        view.vocabulary = ["quick"]
        view.string = "qui"
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.refreshCompletion()
        view.doCommand(by: #selector(NSTextView.insertTab(_:)))
        XCTAssertEqual(view.string, "quick")
        var closes = 0
        view.escapeHandler = { closes += 1 }
        view.doCommand(by: #selector(NSTextView.cancelOperation(_:)))
        XCTAssertEqual(closes, 1)
    }

    func testStandardTabFocusNavigationKeepsWorkingWithCommandsOff() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                              styleMask: .borderless, backing: .buffered, defer: true)
        let root = NSView(), view = CompletionTextView(), next = NSTextView()
        root.addSubview(view)
        root.addSubview(next)
        window.contentView = root
        view.nextKeyView = next
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertFalse(view.commandShortcutsEnabled)
        view.doCommand(by: #selector(NSTextView.insertTab(_:)))
        XCTAssertTrue(window.firstResponder === next)
    }

    func testFocusRequestedBeforeWindowAttachmentIsNotLost() {
        let editor = CompletionEditorContainerView(style: .singleLine)
        editor.requestFocus(UUID())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = editor
        XCTAssertTrue(window.firstResponder === editor.textView)
    }

    func testRepeatedFocusRequestDoesNotStealFocusFromAnotherControl() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: true)
        let root = NSView(), editor = CompletionEditorContainerView(style: .singleLine), other = NSTextView()
        root.addSubview(editor)
        root.addSubview(other)
        window.contentView = root
        let id = UUID()
        editor.requestFocus(id)
        XCTAssertTrue(window.firstResponder === editor.textView)
        XCTAssertTrue(window.makeFirstResponder(other))
        editor.requestFocus(id)
        XCTAssertTrue(window.firstResponder === other)
        editor.requestFocus(UUID())
        XCTAssertTrue(window.firstResponder === editor.textView)
    }

    func testPanelInputIsReadySynchronouslyWithoutWaitingForSwiftUIFocusUpdate() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: true)
        let root = NSView(), wrapper = NSView()
        let multiline = CompletionEditorContainerView(style: .multiline)
        let input = CompletionEditorContainerView(style: .singleLine)
        root.addSubview(multiline)
        wrapper.addSubview(input)
        root.addSubview(wrapper)
        window.contentView = root
        CompletionEditorContainerView.focusCaptureInput(in: window)
        XCTAssertTrue(window.firstResponder === input.textView)
        XCTAssertTrue(window.initialFirstResponder === input.textView)
        input.textView.insertText("quick", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(input.textView.string, "quick")
    }

    private func event(code: UInt16, flags: NSEvent.ModifierFlags = [.command]) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                      isARepeat: false, keyCode: code))
    }
}
