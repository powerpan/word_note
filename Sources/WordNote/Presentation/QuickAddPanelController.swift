import AppKit
import SwiftData
import SwiftUI
import WordNoteCore

@MainActor
final class QuickAddPanelController {
    private let modelContainer: ModelContainer
    private let analysisQueue: QuickAddAnalysisQueue
    private var panel: QuickAddFloatingPanel?

    init(modelContainer: ModelContainer, analysisQueue: QuickAddAnalysisQueue) {
        self.modelContainer = modelContainer
        self.analysisQueue = analysisQueue
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel

        position(panel)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .quickAddPanelDidShow, object: nil)
    }

    func close() {
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
        panel.title = "Quick Add"
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
            onClose: { [weak self] in self?.close() }
        )
        .modelContainer(modelContainer)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        panel.contentView = hostingView
        return panel
    }

    private func position(_ panel: NSPanel) {
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let margin: CGFloat = 18
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.maxX - panel.frame.width - margin,
                y: visibleFrame.maxY - panel.frame.height - margin
            )
        )
    }

    private func resizePanel(_ panel: NSPanel?, height: CGFloat) {
        guard let panel else { return }

        let size = NSSize(width: FloatingQuickAddMetrics.width, height: height)
        let topRight = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
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
    }
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
    static let explanationBaseHeight: CGFloat = 102
    static let minExpandedHeight: CGFloat = 132
    static let maxExpandedHeight: CGFloat = 270
    static let explanationDisplayDurationSeconds: TimeInterval = 10

    static var collapsedPanelSize: NSSize {
        NSSize(width: width, height: collapsedHeight)
    }

    static func expandedHeight(for explanationContentHeight: CGFloat) -> CGFloat {
        min(
            max(explanationBaseHeight + explanationContentHeight, minExpandedHeight),
            maxExpandedHeight
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
