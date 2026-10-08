import AppKit
import SwiftUI
import WordNoteCore

struct VocabularyCompletionEditor: NSViewRepresentable {
    enum Style {
        case multiline
        case singleLine

        var isMultiline: Bool { self == .multiline }

        var font: NSFont {
            switch self {
            case .multiline:
                NSFont.systemFont(ofSize: NSFont.systemFontSize)
            case .singleLine:
                NSFont.systemFont(ofSize: 14, weight: .medium)
            }
        }

        var textContainerInset: NSSize {
            switch self {
            case .multiline:
                NSSize(width: 12, height: 12)
            case .singleLine:
                NSSize(width: 13, height: 10)
            }
        }
    }

    @Binding var text: String
    let vocabulary: [String]
    let placeholder: String
    let style: Style
    var focusRequestID: UUID?
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onCommandSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> CompletionEditorContainerView {
        let container = CompletionEditorContainerView(style: style)
        let textView = container.textView
        textView.delegate = context.coordinator
        configure(textView, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ container: CompletionEditorContainerView, context: Context) {
        context.coordinator.parent = self
        let textView = container.textView
        configure(textView, coordinator: context.coordinator)

        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }

        textView.vocabulary = vocabulary
        container.updateDocumentFrame()
        textView.refreshCompletion()

        if let focusRequestID { container.requestFocus(focusRequestID) }
    }

    static func dismantleNSView(_ container: CompletionEditorContainerView, coordinator: Coordinator) {
        container.textView.delegate = nil
    }

    private func configure(_ textView: CompletionTextView, coordinator: Coordinator) {
        textView.placeholder = placeholder
        textView.font = style.font
        textView.textContainerInset = style.textContainerInset
        textView.isMultiline = style.isMultiline
        textView.submitHandler = onSubmit
        textView.escapeHandler = onEscape
        textView.commandSubmitHandler = onCommandSubmit
        textView.bindingUpdateHandler = { [weak coordinator] updatedText in
            coordinator?.updateBinding(with: updatedText)
        }
        textView.setAccessibilityLabel("Quick Add input")
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: VocabularyCompletionEditor

        init(parent: VocabularyCompletionEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            completionTextView(from: notification)?.refreshCompletion()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = completionTextView(from: notification) else { return }
            updateBinding(with: textView.string)
            textView.updateDocumentFrame()
            textView.refreshCompletion()
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            completionTextView(from: notification)?.refreshCompletion()
        }

        func textDidEndEditing(_ notification: Notification) {
            completionTextView(from: notification)?.hideCompletion()
        }

        func updateBinding(with updatedText: String) {
            guard parent.text != updatedText else { return }
            parent.text = updatedText
        }

        private func completionTextView(from notification: Notification) -> CompletionTextView? {
            notification.object as? CompletionTextView
        }
    }
}

final class CompletionEditorContainerView: NSView {
    let textView = CompletionTextView()
    private let scrollView = NSScrollView()
    private let style: VocabularyCompletionEditor.Style
    private var pendingFocusRequestID: UUID?
    private var lastFocusRequestID: UUID?

    init(style: VocabularyCompletionEditor.Style) {
        self.style = style
        super.init(frame: .zero)

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = style.isMultiline
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = style.isMultiline
        textView.textContainer?.maximumNumberOfLines = style.isMultiline ? 0 : 1
        textView.textContainer?.lineBreakMode = style.isMultiline ? .byWordWrapping : .byClipping
        textView.isHorizontallyResizable = !style.isMultiline
        textView.isVerticallyResizable = style.isMultiline
        textView.autoresizingMask = style.isMultiline ? [.width] : [.height]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: style.isMultiline ? CGFloat.greatestFiniteMagnitude : 40
        )
        textView.textContainer?.containerSize = NSSize(
            width: style.isMultiline ? 0 : CGFloat.greatestFiniteMagnitude,
            height: style.isMultiline ? CGFloat.greatestFiniteMagnitude : 40
        )

        scrollView.documentView = textView
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPendingFocus()
    }

    func requestFocus(_ id: UUID) {
        guard id != lastFocusRequestID else { return }
        pendingFocusRequestID = id
        applyPendingFocus()
    }

    private func applyPendingFocus() {
        guard let id = pendingFocusRequestID, let window, window.makeFirstResponder(textView) else { return }
        lastFocusRequestID = id
        pendingFocusRequestID = nil
    }

    static func focusCaptureInput(in window: NSWindow) {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        guard let editor = captureEditor(in: content) else { return }
        window.initialFirstResponder = editor.textView
        window.makeFirstResponder(editor.textView)
    }

    private static func captureEditor(in view: NSView) -> CompletionEditorContainerView? {
        if let editor = view as? CompletionEditorContainerView, !editor.style.isMultiline { return editor }
        for child in view.subviews {
            if let editor = captureEditor(in: child) { return editor }
        }
        return nil
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds

        updateDocumentFrame()
    }

    func updateDocumentFrame() {
        let contentBounds = scrollView.contentView.bounds
        guard contentBounds.width > 0, contentBounds.height > 0 else { return }

        if style.isMultiline {
            textView.frame.size.width = contentBounds.width
            if let layoutManager = textView.layoutManager,
               let textContainer = textView.textContainer {
                layoutManager.ensureLayout(for: textContainer)
                let usedHeight = layoutManager.usedRect(for: textContainer).height
                    + (textView.textContainerInset.height * 2)
                textView.frame.size.height = max(contentBounds.height, ceil(usedHeight))
            }
        } else {
            var requiredWidth = contentBounds.width
            if let layoutManager = textView.layoutManager,
               let textContainer = textView.textContainer {
                layoutManager.ensureLayout(for: textContainer)
                requiredWidth = max(
                    requiredWidth,
                    ceil(layoutManager.usedRect(for: textContainer).width)
                        + (textView.textContainerInset.width * 2)
                        + 2
                )
            }
            textView.frame = NSRect(
                x: 0,
                y: 0,
                width: requiredWidth,
                height: contentBounds.height
            )
        }
    }
}

final class CompletionTextView: NSTextView {
    var vocabulary: [String] = []
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var isMultiline = true
    var submitHandler: (() -> Void)?
    var escapeHandler: (() -> Void)?
    var commandSubmitHandler: (() -> Void)?
    var bindingUpdateHandler: ((String) -> Void)?

    private var completion: VocabularyCompletion?
    private var dismissedInput: String?
    private var isHandlingMarkedTextKeyEvent = false

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            refreshCompletion()
        }
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder {
            hideCompletion()
        }
        return didResignFirstResponder
    }

    override func keyDown(with event: NSEvent) {
        let startedWithMarkedText = hasMarkedText()
        if !startedWithMarkedText, isCommandReturn(event), commandSubmitHandler != nil {
            submitCommandReturn()
            return
        }
        if startedWithMarkedText {
            isHandlingMarkedTextKeyEvent = true
        }

        defer {
            if startedWithMarkedText {
                isHandlingMarkedTextKeyEvent = false
            }
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard (window == nil || window?.firstResponder === self),
              isCommandReturn(event), commandSubmitHandler != nil else {
            return super.performKeyEquivalent(with: event)
        }
        if hasMarkedText() {
            // Let the IME commit first; consuming this event prevents the window button from submitting.
            keyDown(with: event)
        } else { submitCommandReturn() }
        return true
    }

    private func isCommandReturn(_ event: NSEvent) -> Bool {
        event.type == .keyDown && [36, 76].contains(event.keyCode)
            && event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
    }

    private func submitCommandReturn() {
        bindingUpdateHandler?(string)
        commandSubmitHandler?()
    }

    override func doCommand(by commandSelector: Selector) {
        if isHandlingMarkedTextKeyEvent, isCompletionCommand(commandSelector) {
            return
        }

        if hasMarkedText() {
            super.doCommand(by: commandSelector)
            return
        }

        if commandSelector == #selector(insertTab(_:)) {
            if acceptCompletion() {
                return
            }

            window?.selectNextKeyView(self)
            return
        }

        if commandSelector == #selector(insertBacktab(_:)) {
            window?.selectPreviousKeyView(self)
            return
        }

        if commandSelector == #selector(insertNewline(_:))
            || commandSelector == #selector(insertNewlineIgnoringFieldEditor(_:)) {
            if isMultiline {
                super.doCommand(by: commandSelector)
            } else {
                submitHandler?()
            }
            return
        }

        if commandSelector == #selector(cancelOperation(_:)) {
            if completion != nil {
                dismissedInput = string
                hideCompletion()
            } else if let escapeHandler {
                escapeHandler()
            } else {
                super.doCommand(by: commandSelector)
            }
            return
        }

        super.doCommand(by: commandSelector)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if string.isEmpty {
            drawPlaceholder()
        } else if let completion {
            drawCompletionSuffix(completion.suffix)
        }
    }

    func refreshCompletion() {
        if dismissedInput != string {
            dismissedInput = nil
        }

        let textLength = (string as NSString).length
        let selection = selectedRange()
        let isActiveEditor = window?.firstResponder === self
        let canSuggest = isActiveEditor
            && dismissedInput != string
            && selection.length == 0
            && selection.location == textLength
            && !hasMarkedText()

        completion = canSuggest
            ? VocabularyCompletionMatcher.bestCompletion(for: string, candidates: vocabulary)
            : nil
        needsDisplay = true
    }

    func hideCompletion() {
        completion = nil
        needsDisplay = true
    }

    func updateDocumentFrame() {
        (enclosingScrollView?.superview as? CompletionEditorContainerView)?.updateDocumentFrame()
    }

    private func acceptCompletion() -> Bool {
        guard let completion else { return false }
        let insertionRange = selectedRange()
        guard shouldChangeText(in: insertionRange, replacementString: completion.suffix) else {
            return false
        }

        textStorage?.replaceCharacters(in: insertionRange, with: completion.suffix)
        didChangeText()
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        bindingUpdateHandler?(string)
        updateDocumentFrame()
        scrollRangeToVisible(selectedRange())
        dismissedInput = nil
        refreshCompletion()
        return true
    }

    private func drawPlaceholder() {
        guard !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(
            at: textContainerOrigin,
            withAttributes: textAttributes(color: .placeholderTextColor)
        )
    }

    private func drawCompletionSuffix(_ suffix: String) {
        guard let layoutManager,
              let textContainer,
              !suffix.isEmpty else {
            return
        }

        let textLength = (string as NSString).length
        guard textLength > 0 else { return }

        layoutManager.ensureLayout(for: textContainer)
        let lastCharacterRange = NSRange(location: textLength - 1, length: 1)
        let lastGlyphRange = layoutManager.glyphRange(
            forCharacterRange: lastCharacterRange,
            actualCharacterRange: nil
        )
        let lastGlyphBounds = layoutManager.boundingRect(
            forGlyphRange: lastGlyphRange,
            in: textContainer
        )
        let drawPoint = NSPoint(
            x: textContainerOrigin.x + lastGlyphBounds.maxX,
            y: textContainerOrigin.y + lastGlyphBounds.minY
        )

        (suffix as NSString).draw(
            at: drawPoint,
            withAttributes: textAttributes(color: .tertiaryLabelColor)
        )
    }

    private func textAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: color
        ]
    }

    private func isCompletionCommand(_ commandSelector: Selector) -> Bool {
        commandSelector == #selector(insertTab(_:))
            || commandSelector == #selector(insertBacktab(_:))
            || commandSelector == #selector(insertNewline(_:))
            || commandSelector == #selector(insertNewlineIgnoringFieldEditor(_:))
            || commandSelector == #selector(cancelOperation(_:))
    }
}
