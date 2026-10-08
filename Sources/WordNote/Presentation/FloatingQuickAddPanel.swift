import AppKit
import SwiftData
import SwiftUI
import WordNoteCore

struct FloatingQuickAddPanelView: View {
    let analysisQueue: QuickAddAnalysisQueue
    let onHeightChange: (CGFloat) -> Void
    let onClose: () -> Void
    var resultPresentation: CaptureResultPresentation? = nil
    var layout: FloatingQuickAddLayout? = nil
    var resultActions: CaptureResultActions? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.captureContext) private var captureContext
    @Environment(\.captureNavigator) private var captureNavigator
    @AppStorage(AppAppearancePreference.storageKey) private var appearanceRawValue = AppAppearancePreference.system.rawValue
    @AppStorage("defaultSourceType") private var defaultSourceType = SourceType.other.rawValue
    @Query private var storedTerms: [TermModel]
    @State private var rawText = ""
    @State private var inputFocusRequestID = UUID()
    #if !WORDNOTE_V2_VALIDATION && !WORDNOTE_V3_VALIDATION
    @State private var displayedExplanation: AIExplanationPreview?
    @State private var explanationHideToken = UUID()
    @State private var explanationHideTask: Task<Void, Never>?
    @State private var explanationHideStartedAt: Date?
    @State private var explanationRemainingHideTime = FloatingQuickAddMetrics.explanationDisplayDurationSeconds
    @State private var explanationContentHeight: CGFloat = 0
    @State private var panelIsFocused = false
    #else
    @State private var explanationContentHeight: CGFloat = 0
    @State private var showsTasks = false
    #endif
    @State private var showsContext = false
    @State private var submissionError: String?
    @State private var errorContentHeight: CGFloat = 0

    private var canSubmit: Bool {
        !TextNormalizer.isBlank(rawText)
    }

    private var selectedSourceType: SourceType {
        SourceType(rawValue: defaultSourceType) ?? .other
    }

    private var selectedAppearance: AppAppearancePreference {
        AppAppearancePreference.resolved(from: appearanceRawValue)
    }

    #if !WORDNOTE_V2_VALIDATION && !WORDNOTE_V3_VALIDATION
    private var latestExplanationKey: String {
        guard let latestAIExplanation = analysisQueue.latestAIExplanation else { return "none" }
        let candidateKey = latestAIExplanation.candidates
            .map { "\($0.id):\($0.chineseMeaning ?? ""):\($0.englishDefinition ?? "")" }
            .joined(separator: "|")
        return [
            latestAIExplanation.id.uuidString,
            latestAIExplanation.rawText,
            latestAIExplanation.sentenceMeaning ?? "",
            candidateKey
        ].joined(separator: "|")
    }
    #endif

    private var visibleExplanation: AIExplanationPreview? {
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        resultPresentation?.event?.preview
        #else
        displayedExplanation
        #endif
    }

    private var preferredPanelHeight: CGFloat {
        let base = visibleExplanation == nil ? FloatingQuickAddMetrics.collapsedHeight
            : FloatingQuickAddMetrics.expandedHeight(for: explanationContentHeight, maximumHeight: layout?.maximumHeight)
        return min(base + (submissionError == nil ? 0 : errorHeight + 11), layout?.maximumHeight ?? .greatestFiniteMagnitude)
    }

    private var errorHeight: CGFloat { min(max(errorContentHeight, 24), 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            inputRow

            if let submissionError {
                ScrollView {
                    HStack(alignment: .top, spacing: 8) {
                        Label(AppLocalization.text(submissionError), systemImage: "exclamationmark.triangle")
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Dismiss Error", systemImage: "xmark") { self.submissionError = nil }
                            .labelStyle(.iconOnly).buttonStyle(.plain).help("Dismiss capture error")
                    }
                    .measureHeight($errorContentHeight)
                }
                .frame(height: errorHeight)
            }

            if let visibleExplanation {
                Divider()
                FloatingExplanationResultsView(
                    explanation: visibleExplanation,
                    direction: resultPresentation?.event?.direction,
                    contentHeight: $explanationContentHeight,
                    actions: resultActions,
                    onOpen: openResultAction
                )
            }
        }
        .padding(10)
        .frame(
            width: FloatingQuickAddMetrics.width,
            height: preferredPanelHeight,
            alignment: .topLeading
        )
        .background(WordNoteTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(WordNoteTheme.strongLine, lineWidth: 1)
        }
        .preferredColorScheme(selectedAppearance.preferredColorScheme)
        .background {
            if let resultPresentation { CaptureResultWindowBridge(presentation: resultPresentation) }
        }
        .onAppear {
            #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
            if let resultPresentation { analysisQueue.feedback.subscribe(resultPresentation) }
            #endif
            focusInput()
            onHeightChange(preferredPanelHeight)
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickAddPanelDidShow)) { _ in
            #if !WORDNOTE_V2_VALIDATION && !WORDNOTE_V3_VALIDATION
            updatePanelFocus(true)
            #endif
            focusInput()
            onHeightChange(preferredPanelHeight)
        }
        #if !WORDNOTE_V2_VALIDATION && !WORDNOTE_V3_VALIDATION
        .onReceive(NotificationCenter.default.publisher(for: .quickAddPanelFocusDidChange)) { notification in
            let isFocused = notification.userInfo?[QuickAddPanelFocusUserInfoKey.isFocused] as? Bool ?? false
            updatePanelFocus(isFocused)
        }
        .onChange(of: latestExplanationKey) {
            showLatestExplanation()
        }
        #else
        .onChange(of: resultPresentation?.event?.preview.id) {
            explanationContentHeight = 0
        }
        #endif
        .onChange(of: preferredPanelHeight) {
            onHeightChange(preferredPanelHeight)
        }
        .onDisappear {
            #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
            if let resultPresentation { analysisQueue.feedback.unsubscribe(resultPresentation) }
            resultActions?.reset()
            #else
            cancelExplanationHideTimer()
            #endif
        }
        .onExitCommand(perform: onClose)
    }

    private var openResultAction: (() -> Void)? {
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        guard let target = resultPresentation?.event?.target, let captureNavigator else { return nil }
        return {
            do { try captureNavigator.open(target) }
            catch { resultActions?.showError(error) }
        }
        #else
        nil
        #endif
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            VocabularyCompletionEditor(
                text: $rawText,
                vocabulary: storedTerms.map(\.term),
                placeholder: "English or Chinese lookup",
                style: .singleLine,
                focusRequestID: inputFocusRequestID,
                onSubmit: submit,
                onEscape: onClose
            )
                .frame(height: 40)
                .background(WordNoteTheme.field)
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(WordNoteTheme.line, lineWidth: 1)
                }

            if let captureContext {
                Button("Capture Context", systemImage: "slider.horizontal.3") { showsContext.toggle() }
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .frame(width: 24, height: 32)
                    .foregroundStyle(captureContext.courseWarning == nil && captureContext.preferenceWarning == nil ? WordNoteTheme.mutedInk : WordNoteTheme.amber)
                    .help(AppLocalization.text(captureContext.courseWarning ?? captureContext.preferenceWarning ?? "Course, source and lookup direction"))
                    .popover(isPresented: $showsContext, arrowEdge: .bottom) {
                        CaptureContextFields(controller: captureContext)
                            .padding(16).frame(width: 300)
                            .background {
                                if let resultPresentation { CaptureResultWindowBridge(presentation: resultPresentation, ownsVisibility: false) }
                            }
                    }
            }

            #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
            if !analysisQueue.jobs.isEmpty || analysisQueue.isSuspended { tasksButton }
            #endif

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .foregroundStyle(canSubmit ? WordNoteTheme.brand : WordNoteTheme.mutedInk.opacity(0.45))
            .help("Add term or analyze input")
            .accessibilityLabel("Add term or analyze input")
        }
    }

    #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
    private var tasksButton: some View {
        let pending = analysisQueue.jobs.filter { $0.state == .queued || $0.state == .running }.count
        let failed = analysisQueue.failedCount
        return Button { showsTasks.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: analysisQueue.isSuspended ? "pause.circle" : "clock")
                if pending > 0 { Text(pending > 99 ? "99+" : "\(pending)").monospacedDigit() }
                if failed > 0 {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(WordNoteTheme.amber)
                    Text(failed > 99 ? "99+" : "\(failed)").monospacedDigit()
                }
            }.font(.caption).frame(height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Analysis tasks: \(pending) pending, \(failed) failed\(analysisQueue.isSuspended ? AppLocalization.text(", paused") : "")")
        .help("\(pending) pending, \(failed) failed\(analysisQueue.isSuspended ? AppLocalization.text("; analysis paused") : "")")
        .popover(isPresented: $showsTasks, arrowEdge: .bottom) {
            V2AnalysisTasksView(queue: analysisQueue, startsExpanded: true)
                .frame(width: 320)
                .background {
                    if let resultPresentation { CaptureResultWindowBridge(presentation: resultPresentation, ownsVisibility: false) }
                }
        }
    }
    #endif

    private func submit() {
        guard canSubmit else { return }
        let text = rawText

        do {
            #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
            guard let captureContext else { throw CaptureContextError.unavailable }
            let request = try captureContext.request(rawText: text, capturedVia: .floatingQuickAdd, modelContext: modelContext)
            try analysisQueue.enqueue(request)
            #else
            try analysisQueue.enqueue(
                rawText: text,
                courseID: nil,
                courseName: nil,
                sourceType: selectedSourceType,
                note: nil,
                capturedVia: .floatingQuickAdd
            )
            #endif
            rawText = ""
            submissionError = nil
            focusInput()
        } catch {
            #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
            submissionError = error.localizedDescription
            #endif
            NSSound.beep()
        }
    }

    #if !WORDNOTE_V2_VALIDATION && !WORDNOTE_V3_VALIDATION
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
    #endif

    private func focusInput() {
        inputFocusRequestID = UUID()
    }
}

private struct FloatingExplanationResultsView: View {
    let explanation: AIExplanationPreview
    let direction: LookupDirection?
    @Binding var contentHeight: CGFloat
    var actions: CaptureResultActions?
    var onOpen: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(explanation.floatingRows(direction: direction ?? LookupDirectionDetector.detect(explanation.rawText))) { row in
                    explanationRow(row)
                }
                if let message = actions?.message {
                    Label(AppLocalization.text(message), systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(WordNoteTheme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 4)
            .measureHeight($contentHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(WordNoteTheme.brand)
    }

    private func explanationRow(_ row: FloatingExplanationRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text(row.source).fontWeight(.semibold) + Text("：\(row.meaning)"))
                .font(.callout)
                .lineSpacing(4)
                .foregroundStyle(row.isMuted ? WordNoteTheme.mutedInk : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let actions {
                HStack(spacing: 6) {
                    if row.englishText != nil {
                        Button { actions.copy(row) } label: {
                            Image(systemName: actions.copiedRowID == row.id ? "checkmark" : "doc.on.doc").frame(width: 26, height: 24)
                        }
                        .help(actions.copiedRowID == row.id ? "English copied" : "Copy English")
                        .accessibilityLabel(actions.copiedRowID == row.id ? "English copied" : "Copy English")
                        Button { actions.toggleSpeech(row) } label: {
                            Image(systemName: actions.speakingRowID == row.id ? "stop.fill" : "speaker.wave.2").frame(width: 26, height: 24)
                        }
                        .help(actions.speakingRowID == row.id ? "Stop speaking" : "Speak English")
                        .accessibilityLabel(actions.speakingRowID == row.id ? "Stop speaking" : "Speak English")
                    }
                    Spacer(minLength: 0)
                    if let onOpen {
                        Button(action: onOpen) { Image(systemName: "arrow.up.forward.app").frame(width: 26, height: 24) }
                            .help("Open record in main window").accessibilityLabel("Open record in main window")
                    }
                }
                .buttonStyle(.plain).foregroundStyle(WordNoteTheme.mutedInk)
            }
        }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WordNoteTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(WordNoteTheme.line, lineWidth: 1)
            }
    }
}

private struct MeasuredHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

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
