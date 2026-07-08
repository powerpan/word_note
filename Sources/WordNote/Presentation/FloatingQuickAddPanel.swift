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
        let origin = NSPoint(
            x: visibleFrame.maxX - panel.frame.width - margin,
            y: visibleFrame.maxY - panel.frame.height - margin
        )
        panel.setFrameOrigin(origin)
    }

    private func resizePanel(_ panel: NSPanel?, height: CGFloat) {
        guard let panel else { return }

        let size = NSSize(width: FloatingQuickAddMetrics.width, height: height)
        let topRight = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        let frame = NSRect(
            x: topRight.x - size.width,
            y: topRight.y - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true, animate: true)
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

private enum FloatingQuickAddMetrics {
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

private struct FloatingQuickAddPanelView: View {
    let analysisQueue: QuickAddAnalysisQueue
    let onHeightChange: (CGFloat) -> Void
    let onClose: () -> Void

    @AppStorage("defaultSourceType") private var defaultSourceType = SourceType.other.rawValue
    @FocusState private var inputFocused: Bool
    @State private var rawText = ""
    @State private var displayedExplanation: AIExplanationPreview?
    @State private var explanationHideToken = UUID()
    @State private var explanationHideTask: Task<Void, Never>?
    @State private var explanationHideStartedAt: Date?
    @State private var explanationRemainingHideTime = FloatingQuickAddMetrics.explanationDisplayDurationSeconds
    @State private var explanationContentHeight: CGFloat = 0
    @State private var panelIsFocused = false

    private var canSubmit: Bool {
        !TextNormalizer.isBlank(rawText)
    }

    private var selectedSourceType: SourceType {
        SourceType(rawValue: defaultSourceType) ?? .other
    }

    private var latestExplanationKey: String {
        guard let latestAIExplanation = analysisQueue.latestAIExplanation else { return "none" }
        let candidateKey = latestAIExplanation.candidates
            .map { "\($0.id):\($0.chineseMeaning ?? "")" }
            .joined(separator: "|")
        return [
            latestAIExplanation.rawText,
            latestAIExplanation.sentenceMeaning ?? "",
            candidateKey
        ].joined(separator: "|")
    }

    private var preferredPanelHeight: CGFloat {
        if displayedExplanation != nil {
            return FloatingQuickAddMetrics.expandedHeight(for: explanationContentHeight)
        }

        return FloatingQuickAddMetrics.collapsedHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            inputRow

            if let displayedExplanation {
                Divider()
                FloatingChineseExplanationView(
                    explanation: displayedExplanation,
                    contentHeight: $explanationContentHeight
                )
            }
        }
        .padding(10)
        .frame(
            width: FloatingQuickAddMetrics.width,
            height: preferredPanelHeight,
            alignment: .topLeading
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .onAppear {
            focusInput()
            onHeightChange(preferredPanelHeight)
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickAddPanelDidShow)) { _ in
            updatePanelFocus(true)
            focusInput()
            onHeightChange(preferredPanelHeight)
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickAddPanelFocusDidChange)) { notification in
            let isFocused = notification.userInfo?[QuickAddPanelFocusUserInfoKey.isFocused] as? Bool ?? false
            updatePanelFocus(isFocused)
        }
        .onChange(of: latestExplanationKey) {
            showLatestExplanation()
        }
        .onChange(of: preferredPanelHeight) {
            onHeightChange(preferredPanelHeight)
        }
        .onDisappear {
            cancelExplanationHideTimer()
        }
        .onExitCommand(perform: onClose)
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Add word, phrase, or sentence", text: $rawText)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .focused($inputFocused)
                .onSubmit(submit)
                .padding(.horizontal, 13)
                .frame(height: 40)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.88))
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                }

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .foregroundStyle(canSubmit ? Color.accentColor : Color.secondary.opacity(0.45))
            .help("Add to AI analysis queue")
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let text = rawText

        do {
            try analysisQueue.enqueue(
                rawText: text,
                courseID: nil,
                courseName: nil,
                sourceType: selectedSourceType,
                note: nil
            )
            rawText = ""
            focusInput()
        } catch {
            NSSound.beep()
        }
    }

    private func showLatestExplanation() {
        guard let latestAIExplanation = analysisQueue.latestAIExplanation else {
            hideExplanation()
            return
        }

        displayedExplanation = latestAIExplanation
        explanationContentHeight = 0
        explanationRemainingHideTime = FloatingQuickAddMetrics.explanationDisplayDurationSeconds
        explanationHideStartedAt = nil

        explanationHideToken = UUID()
        scheduleExplanationHideIfNeeded()
    }

    private func updatePanelFocus(_ isFocused: Bool) {
        guard panelIsFocused != isFocused else { return }
        panelIsFocused = isFocused

        if isFocused {
            pauseExplanationHideTimer()
        } else {
            scheduleExplanationHideIfNeeded()
        }
    }

    private func scheduleExplanationHideIfNeeded() {
        guard displayedExplanation != nil else { return }
        guard !panelIsFocused else { return }

        if explanationRemainingHideTime <= 0 {
            hideExplanation()
            return
        }

        cancelExplanationHideTimer()

        let hideToken = explanationHideToken
        let remainingNanoseconds = UInt64(explanationRemainingHideTime * 1_000_000_000)
        explanationHideStartedAt = Date()

        explanationHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: remainingNanoseconds)
            guard !Task.isCancelled else { return }
            if explanationHideToken == hideToken, !panelIsFocused {
                hideExplanation()
            }
        }
    }

    private func pauseExplanationHideTimer() {
        cancelExplanationHideTimer()

        guard let explanationHideStartedAt else { return }
        let elapsedTime = Date().timeIntervalSince(explanationHideStartedAt)
        explanationRemainingHideTime = max(0, explanationRemainingHideTime - elapsedTime)
        self.explanationHideStartedAt = nil
    }

    private func cancelExplanationHideTimer() {
        explanationHideTask?.cancel()
        explanationHideTask = nil
    }

    private func hideExplanation() {
        cancelExplanationHideTimer()
        displayedExplanation = nil
        explanationHideStartedAt = nil
        explanationRemainingHideTime = FloatingQuickAddMetrics.explanationDisplayDurationSeconds
        explanationHideToken = UUID()
    }

    private func focusInput() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            inputFocused = true
        }
    }
}

private struct FloatingChineseExplanationView: View {
    let explanation: AIExplanationPreview
    @Binding var contentHeight: CGFloat

    private var chineseCandidates: [AIExplanationCandidatePreview] {
        explanation.candidates.filter { $0.chineseMeaning != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("中文釋義", systemImage: "text.bubble")
                .font(.system(size: 12, weight: .semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if let sentenceMeaning = explanation.sentenceMeaning {
                        Text(sentenceMeaning)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(chineseCandidates) { candidate in
                        if let chineseMeaning = candidate.chineseMeaning {
                            Text(chineseMeaning)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    if explanation.sentenceMeaning == nil, chineseCandidates.isEmpty {
                        Text("這次分析沒有返回可顯示的中文釋義。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
                .measureHeight($contentHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MeasuredHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func measureHeight(_ height: Binding<CGFloat>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: MeasuredHeightKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(MeasuredHeightKey.self) { measuredHeight in
            height.wrappedValue = measuredHeight
        }
    }
}

private extension Notification.Name {
    static let quickAddPanelDidShow = Notification.Name("WordNoteQuickAddPanelDidShow")
    static let quickAddPanelFocusDidChange = Notification.Name("WordNoteQuickAddPanelFocusDidChange")
}

private enum QuickAddPanelFocusUserInfoKey {
    static let isFocused = "isFocused"
}
