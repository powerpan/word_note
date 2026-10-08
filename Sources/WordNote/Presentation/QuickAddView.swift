import SwiftData
import SwiftUI
import WordNoteCore

struct QuickAddView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(QuickAddAnalysisQueue.self) private var analysisQueue
    @Environment(\.captureContext) private var captureContext
    @AppStorage("defaultSourceType") private var defaultSourceType = SourceType.other.rawValue
    @Query private var storedCourses: [CourseModel]
    @Query private var storedTerms: [TermModel]

    @State private var rawText = ""
    @State private var selectedCourseID: UUID?
    @State private var selectedSourceType: SourceType = .other
    @State private var note = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    #if WORDNOTE_V2_VALIDATION
    @State private var resultPresentation = CaptureResultPresentation(mode: .main)
    #endif

    private var courses: [CourseModel] {
        storedCourses.sorted { $0.courseName.localizedStandardCompare($1.courseName) == .orderedAscending }
    }

    private var canSave: Bool {
        !TextNormalizer.isBlank(rawText)
    }

    private var detectedLookupDirection: LookupDirection? {
        guard canSave else { return nil }
        if let captureContext { return captureContext.current.intent.resolvedDirection(for: rawText) }
        return LookupDirectionDetector.detect(rawText)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "Quick Add",
                    subtitle: "Capture English text, or enter Chinese when you need the right English expression."
                ) {
                    EmptyView()
                }

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Input")
                            .font(.headline)

                        VocabularyCompletionEditor(
                            text: $rawText,
                            vocabulary: storedTerms.map(\.term),
                            placeholder: "Enter English text or a Chinese meaning to look up",
                            style: .multiline,
                            onCommandSubmit: commandSubmit
                        )
                            .frame(minHeight: 300)
                            .background(WordNoteTheme.field)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(WordNoteTheme.line, lineWidth: 1)
                            }

                        if let detectedLookupDirection {
                            Label(
                                detectedLookupDirection.displayTitle,
                                systemImage: "arrow.left.arrow.right"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        TextField("Optional note", text: $note, axis: .vertical)
                            .lineLimit(2...4)

                        aiExplanationPanel
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Context")
                            .font(.headline)

                        if let captureContext {
                            CaptureContextFields(controller: captureContext)
                        } else {
                            Picker("Course", selection: $selectedCourseID) {
                                Text("No Course").tag(UUID?.none)
                                ForEach(courses, id: \.id) { course in
                                    Text(course.courseName).tag(Optional(course.id))
                                }
                            }
                            Picker("Source", selection: $selectedSourceType) {
                                ForEach(SourceType.allCases) { sourceType in
                                    Text(sourceType.displayTitle).tag(sourceType)
                                }
                            }
                        }

                        Divider()

                        Button {
                            saveAndAnalyze()
                        } label: {
                            Label("Save & Analyze", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        #if WORDNOTE_V2_VALIDATION
                        .keyboardShortcut(.return, modifiers: [.command])
                        #endif
                        .disabled(!canSave)

                        Button {
                            saveDraft()
                        } label: {
                            Label("Save Draft", systemImage: "tray.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        #if !WORDNOTE_V2_VALIDATION
                        .keyboardShortcut(.return, modifiers: [.command])
                        #endif
                        .disabled(!canSave)

                        if analysisQueue.isBusy {
                            VStack(alignment: .leading, spacing: 8) {
                                ProgressView(analysisQueue.queueStatusText)
                                if analysisQueue.queuedCount > 0 {
                                    Text("\(analysisQueue.queuedCount) queued")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                    .frame(width: 280, alignment: .topLeading)
                    .wordNoteSurface()
                }

                if let statusMessage = statusMessage ?? analysisQueue.statusMessage {
                    StatusBanner(message: statusMessage, kind: .success)
                }

                if let errorMessage = errorMessage ?? analysisQueue.errorMessage {
                    StatusBanner(message: errorMessage, kind: .warning)
                }
            }
            .padding(28)
        }
        .onAppear(perform: applyDefaultSourceType)
        .onChange(of: defaultSourceType) {
            applyDefaultSourceType()
        }
        #if WORDNOTE_V2_VALIDATION
        .background(CaptureResultWindowBridge(presentation: resultPresentation))
        .onAppear { analysisQueue.feedback.subscribe(resultPresentation) }
        .onDisappear { analysisQueue.feedback.unsubscribe(resultPresentation) }
        #endif
    }

    private func saveDraft(statusOverride: String? = nil) {
        #if WORDNOTE_V2_VALIDATION
        do {
            guard let captureContext else { throw CaptureContextError.unavailable }
            let request = try captureContext.request(rawText: rawText, note: note, capturedVia: .mainQuickAdd, modelContext: modelContext)
            try analysisQueue.enqueue(request, analyze: false)
            rawText = ""
            note = ""
            errorMessage = nil
            statusMessage = statusOverride ?? analysisQueue.statusMessage
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
        #else
        let service = InputRecordService(modelContext: modelContext)

        do {
            let record = try service.createDraft(
                rawText: rawText,
                courseID: selectedCourseID,
                sourceType: selectedSourceType,
                note: note
            )
            rawText = ""
            note = ""
            errorMessage = nil
            statusMessage = statusOverride ?? "Saved draft: \(record.rawText)"
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
        #endif
    }

    private func saveAndAnalyze() {
        guard canSave else { return }
        statusMessage = nil
        errorMessage = nil

        do {
            #if WORDNOTE_V2_VALIDATION
            guard let captureContext else { throw CaptureContextError.unavailable }
            let request = try captureContext.request(rawText: rawText, note: note, capturedVia: .mainQuickAdd, modelContext: modelContext)
            try analysisQueue.enqueue(request)
            #else
            let courseName = courses.first { $0.id == selectedCourseID }?.courseName
            try analysisQueue.enqueue(
                rawText: rawText,
                courseID: selectedCourseID,
                courseName: courseName,
                sourceType: selectedSourceType,
                note: note
            )
            #endif

            rawText = ""
            note = ""
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private var commandSubmit: (() -> Void)? {
        #if WORDNOTE_V2_VALIDATION
        saveAndAnalyze
        #else
        nil
        #endif
    }

    private func applyDefaultSourceType() {
        selectedSourceType = SourceType(rawValue: defaultSourceType) ?? .other
    }

    private var displayedAIExplanation: AIExplanationPreview? {
        #if WORDNOTE_V2_VALIDATION
        resultPresentation.event?.preview
        #else
        analysisQueue.latestAIExplanation
        #endif
    }

    @ViewBuilder
    private var aiExplanationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI 釋義產出後展示")
                .font(.headline)

            if let latestAIExplanation = displayedAIExplanation {
                VStack(alignment: .leading, spacing: 10) {
                    Text(latestAIExplanation.rawText)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)

                    if let sentenceMeaning = latestAIExplanation.sentenceMeaning {
                        Text(sentenceMeaning)
                            .font(.callout)
                            .textSelection(.enabled)
                    }

                    if latestAIExplanation.sentenceMeaning == nil,
                       latestAIExplanation.candidates.isEmpty {
                        Text("AI did not return a displayable explanation for this input.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(latestAIExplanation.candidates) { candidate in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(candidate.term)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                TagChip(title: candidate.importance.displayTitle, tint: WordNoteTheme.amber)
                            }

                            if let chineseMeaning = candidate.chineseMeaning {
                                Text(chineseMeaning)
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }

                            if let englishDefinition = candidate.englishDefinition {
                                Text(englishDefinition)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            if let aiContextExplanation = candidate.aiContextExplanation {
                                Text(aiContextExplanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(10)
                        .wordNoteSurface(elevated: true)
                    }
                }
            } else {
                Text("保存並加入 AI 分析隊列後，最新一次分析完成的釋義會臨時顯示在這裡。切換欄目或退出 App 後不保留。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wordNoteSurface()
    }
}
