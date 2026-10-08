import AppKit
import Observation
import SwiftData
import SwiftUI
import WordNoteCore

@MainActor
final class QuickAddPanelController: NSObject {
    private let modelContainer: ModelContainer
    private let analysisQueue: QuickAddAnalysisQueue
    private let dataProtection: WordNoteDataProtection?
    private let captureContext: CaptureContextController?
    private let captureNavigator: CaptureResultNavigator?
    #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
    private let resultPresentation: CaptureResultPresentation
    private let resultActions: CaptureResultActions
    private let layout = FloatingQuickAddLayout()
    #endif
    private var panel: QuickAddFloatingPanel?

    init(
        modelContainer: ModelContainer, analysisQueue: QuickAddAnalysisQueue,
        dataProtection: WordNoteDataProtection? = nil, captureContext: CaptureContextController? = nil,
        captureNavigator: CaptureResultNavigator? = nil
    ) {
        self.modelContainer = modelContainer
        self.analysisQueue = analysisQueue
        self.dataProtection = dataProtection
        self.captureContext = captureContext
        self.captureNavigator = captureNavigator
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        let actions = CaptureResultActions()
        resultActions = actions
        resultPresentation = CaptureResultPresentation(mode: .floating, onResultChange: { [weak actions] in actions?.reset() })
        #endif
        super.init()
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #endif
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func show() {
        guard !WordNoteWriteGate.isBlocked(modelContainer.mainContext) else { return }
        let panel = panel ?? makePanel()
        self.panel = panel

        position(panel)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        CompletionEditorContainerView.focusCaptureInput(in: panel)
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        resultPresentation.setVisible(true)
        #endif
        NotificationCenter.default.post(name: .quickAddPanelDidShow, object: nil)
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func close() {
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        resultPresentation.setVisible(false)
        #endif
        panel?.orderOut(nil)
        NotificationCenter.default.post(
            name: .quickAddPanelFocusDidChange,
            object: panel,
            userInfo: [QuickAddPanelFocusUserInfoKey.isFocused: false]
        )
    }

    private func makePanel() -> QuickAddFloatingPanel {
        let panelSize = FloatingQuickAddMetrics.collapsedPanelSize
        let panel = QuickAddFloatingPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = AppLocalization.text("Quick Add")
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let rootView = FloatingQuickAddPanelView(
            analysisQueue: analysisQueue,
            onHeightChange: { [weak panel, weak self] height in
                self?.resizePanel(panel, height: height)
            },
            onClose: { [weak self] in self?.close() },
            resultPresentation: captureResultPresentation,
            layout: captureLayout,
            resultActions: captureResultActions
        )
        .modelContainer(modelContainer)
        .environment(\.captureContext, captureContext)
        .environment(\.captureNavigator, captureNavigator)
        .modifier(CaptureProtectionModifier(protection: dataProtection))

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        panel.contentView = hostingView
        return panel
    }

    private var captureResultPresentation: CaptureResultPresentation? {
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        resultPresentation
        #else
        nil
        #endif
    }

    private var captureLayout: FloatingQuickAddLayout? {
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        layout
        #else
        nil
        #endif
    }

    private var captureResultActions: CaptureResultActions? {
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        resultActions
        #else
        nil
        #endif
    }

    private func position(_ panel: NSPanel) {
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let margin: CGFloat = 18
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        layout.maximumHeight = FloatingQuickAddMetrics.maximumHeight(in: visibleFrame)
        #endif
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.maxX - panel.frame.width - margin,
                y: visibleFrame.maxY - panel.frame.height - margin
            )
        )
    }

    private func resizePanel(_ panel: NSPanel?, height: CGFloat) {
        guard let panel else { return }

        let topRight = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        layout.maximumHeight = FloatingQuickAddMetrics.maximumHeight(in: visibleFrame)
        let frame = FloatingQuickAddMetrics.fittedFrame(topRight: topRight, height: height, visibleFrame: visibleFrame)
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: true) }
        #else
        let size = NSSize(width: FloatingQuickAddMetrics.width, height: height)
        panel.setFrame(
            NSRect(
                x: topRight.x - size.width,
                y: topRight.y - size.height,
                width: size.width,
                height: size.height
            ),
            display: true,
            animate: true
        )
        #endif
    }

    #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
    @objc private func screenChanged(_ notification: Notification) {
        guard let panel else { return }
        if notification.name == NSWindow.didChangeScreenNotification, notification.object as? NSWindow !== panel { return }
        resizePanel(panel, height: panel.frame.height)
    }
    #endif
}

@MainActor
@Observable
final class FloatingQuickAddLayout {
    var maximumHeight = FloatingQuickAddMetrics.maxExpandedHeight
}

private final class QuickAddFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        NotificationCenter.default.post(
            name: .quickAddPanelFocusDidChange,
            object: self,
            userInfo: [QuickAddPanelFocusUserInfoKey.isFocused: true]
        )
    }

    override func resignKey() {
        super.resignKey()
        NotificationCenter.default.post(
            name: .quickAddPanelFocusDidChange,
            object: self,
            userInfo: [QuickAddPanelFocusUserInfoKey.isFocused: false]
        )
    }
}

enum FloatingQuickAddMetrics {
    static let width: CGFloat = 360
    static let collapsedHeight: CGFloat = 60
    static let explanationBaseHeight: CGFloat = 84
    static let minExpandedHeight: CGFloat = 132
    static let maxExpandedHeight: CGFloat = 320
    static let explanationDisplayDurationSeconds: TimeInterval = 10

    static var collapsedPanelSize: NSSize {
        NSSize(width: width, height: collapsedHeight)
    }

    static func expandedHeight(for explanationContentHeight: CGFloat, maximumHeight: CGFloat? = nil) -> CGFloat {
        min(
            max(explanationBaseHeight + explanationContentHeight, minExpandedHeight),
            maximumHeight ?? maxExpandedHeight
        )
    }

    static func maximumHeight(in visibleFrame: NSRect) -> CGFloat {
        max(collapsedHeight, visibleFrame.height - 36)
    }

    static func fittedFrame(topRight: NSPoint, height: CGFloat, visibleFrame: NSRect) -> NSRect {
        let bounds = visibleFrame.insetBy(dx: 18, dy: 18)
        let fittedHeight = min(max(height, collapsedHeight), maximumHeight(in: visibleFrame))
        return NSRect(
            x: max(bounds.minX, min(topRight.x - width, bounds.maxX - width)),
            y: max(bounds.minY, min(topRight.y - fittedHeight, bounds.maxY - fittedHeight)),
            width: width, height: fittedHeight
        )
    }
}

extension Notification.Name {
    static let quickAddPanelDidShow = Notification.Name("WordNoteQuickAddPanelDidShow")
    static let quickAddPanelFocusDidChange = Notification.Name("WordNoteQuickAddPanelFocusDidChange")
}

enum QuickAddPanelFocusUserInfoKey {
    static let isFocused = "isFocused"
}
