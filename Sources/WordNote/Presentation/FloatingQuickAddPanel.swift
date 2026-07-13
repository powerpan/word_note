import AppKit
import SwiftData
import SwiftUI
import WordNoteCore

struct FloatingQuickAddPanelView: View {
    let analysisQueue: QuickAddAnalysisQueue
    let onHeightChange: (CGFloat) -> Void
    let onClose: () -> Void

    @AppStorage(AppAppearancePreference.storageKey) private var appearanceRawValue = AppAppearancePreference.system.rawValue
    @AppStorage("defaultSourceType") private var defaultSourceType = SourceType.other.rawValue
    @Query private var storedTerms: [TermModel]
    @State private var rawText = ""
    @State private var inputFocusRequestID = UUID()
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

    private var selectedAppearance: AppAppearancePreference {
        AppAppearancePreference.resolved(from: appearanceRawValue)
    }

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
                FloatingExplanationResultsView(
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
        .background(WordNoteTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(WordNoteTheme.strongLine, lineWidth: 1)
        }
        .preferredColorScheme(selectedAppearance.preferredColorScheme)
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

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .foregroundStyle(canSubmit ? WordNoteTheme.brand : WordNoteTheme.mutedInk.opacity(0.45))
            .help("Add term or analyze input")
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
            inputFocusRequestID = UUID()
        }
    }
}

private struct FloatingExplanationResultsView: View {
    let explanation: AIExplanationPreview
    @Binding var contentHeight: CGFloat

    private var chineseCandidates: [AIExplanationCandidatePreview] {
        explanation.candidates.filter { $0.chineseMeaning != nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                if let sentenceMeaning = explanation.sentenceMeaning {
                    explanationRow(source: explanation.rawText, meaning: sentenceMeaning)
                }

                ForEach(chineseCandidates) { candidate in
                    if let chineseMeaning = candidate.chineseMeaning {
                        explanationRow(
                            source: candidateSourceText(for: candidate),
                            meaning: chineseMeaning
                        )
                    }
                }

                if explanation.sentenceMeaning == nil, chineseCandidates.isEmpty {
                    explanationRow(
                        source: explanation.rawText,
                        meaning: "這次分析沒有返回可顯示的中文釋義。",
                        isMuted: true
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 4)
            .measureHeight($contentHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(WordNoteTheme.brand)
    }

    private func candidateSourceText(for candidate: AIExplanationCandidatePreview) -> String {
        if explanation.sentenceMeaning == nil, chineseCandidates.count == 1 {
            return explanation.rawText
        }
        return candidate.term
    }

    private func explanationRow(source: String, meaning: String, isMuted: Bool = false) -> some View {
        (Text(source).fontWeight(.semibold) + Text("：\(meaning)"))
            .font(.callout)
            .lineSpacing(4)
            .foregroundStyle(isMuted ? WordNoteTheme.mutedInk : Color.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
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
