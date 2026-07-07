import SwiftData
import SwiftUI
import WordNoteCore

struct QuickAddView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("defaultSourceType") private var defaultSourceType = SourceType.other.rawValue
    @Query(sort: \CourseModel.courseName) private var courses: [CourseModel]

    @State private var rawText = ""
    @State private var selectedCourseID: UUID?
    @State private var selectedSourceType: SourceType = .other
    @State private var note = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var analysisQueue: [QueuedAnalysisRecord] = []
    @State private var isProcessingAnalysisQueue = false
    @State private var activeAnalysisTitle: String?
    @State private var latestAIExplanation: AIExplanationPreview?

    private var canSave: Bool {
        !TextNormalizer.isBlank(rawText)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "Quick Add",
                    subtitle: "Capture a phrase, lecture sentence, slide excerpt, or paper term before turning it into candidates."
                ) {
                    EmptyView()
                }

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Input")
                            .font(.headline)

                        TextEditor(text: $rawText)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 300)
                            .padding(12)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                            }
                            .overlay(alignment: .topLeading) {
                                if rawText.isEmpty {
                                    Text("Paste English text from class, papers, slides, or assignments")
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 20)
                                        .allowsHitTesting(false)
                                }
                            }

                        TextField("Optional note", text: $note, axis: .vertical)
                            .lineLimit(2...4)

                        aiExplanationPanel
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Context")
                            .font(.headline)

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

                        Divider()

                        Button {
                            saveAndAnalyze()
                        } label: {
                            Label("Save & Analyze", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave)

                        Button {
                            saveDraft()
                        } label: {
                            Label("Save Draft", systemImage: "tray.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(!canSave)

                        if isProcessingAnalysisQueue || !analysisQueue.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ProgressView(queueStatusText)
                                if !analysisQueue.isEmpty {
                                    Text("\(analysisQueue.count) queued")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                    .frame(width: 280, alignment: .topLeading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if let statusMessage {
                    StatusBanner(message: statusMessage, kind: .success)
                }

                if let errorMessage {
                    StatusBanner(message: errorMessage, kind: .warning)
                }
            }
            .padding(28)
        }
        .onAppear(perform: applyDefaultSourceType)
        .onChange(of: defaultSourceType) {
            applyDefaultSourceType()
        }
    }

    private func saveDraft(statusOverride: String? = nil) {
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
    }

    private func saveAndAnalyze() {
        let service = InputRecordService(modelContext: modelContext)
        statusMessage = nil
        errorMessage = nil

        do {
            let createdRecord = try service.createAnalyzing(
                rawText: rawText,
                courseID: selectedCourseID,
                sourceType: selectedSourceType,
                note: note
            )
            let courseName = courses.first { $0.id == selectedCourseID }?.courseName

            rawText = ""
            note = ""
            analysisQueue.append(QueuedAnalysisRecord(record: createdRecord, courseName: courseName))
            statusMessage = "Queued for AI analysis: \(createdRecord.rawText)"
            processNextQueuedAnalysisIfNeeded()
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func applyDefaultSourceType() {
        selectedSourceType = SourceType(rawValue: defaultSourceType) ?? .other
    }

    private var queueStatusText: String {
        if let activeAnalysisTitle {
            return "Analyzing: \(activeAnalysisTitle)"
        }
        return "Preparing AI analysis..."
    }

    @ViewBuilder
    private var aiExplanationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI 釋義產出後展示")
                .font(.headline)

            if let latestAIExplanation {
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
                                TagChip(title: candidate.importance.displayTitle, tint: .orange)
                            }

                            if let chineseMeaning = candidate.chineseMeaning {
                                Text(chineseMeaning)
                                    .font(.callout)
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
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func processNextQueuedAnalysisIfNeeded() {
        guard !isProcessingAnalysisQueue, !analysisQueue.isEmpty else { return }

        isProcessingAnalysisQueue = true
        let queuedRecord = analysisQueue.removeFirst()
        activeAnalysisTitle = queuedRecord.record.rawText

        Task { @MainActor in
            let service = InputRecordService(modelContext: modelContext)

            do {
                guard let apiKey = DeepSeekAPIKeyResolver.resolve() else {
                    try service.markFailed(queuedRecord.record, summary: AIAnalysisError.missingAPIKey.localizedDescription)
                    throw AIAnalysisError.missingAPIKey
                }

                let analysisService = AIAnalysisService(
                    client: DeepSeekChatClient(apiKey: apiKey)
                )
                let result = try await analysisService.analyze(
                    AIAnalysisRequest(
                        rawText: queuedRecord.record.rawText,
                        courseName: queuedRecord.courseName,
                        sourceType: queuedRecord.record.sourceType,
                        userNote: queuedRecord.record.note
                    )
                )
                let candidates = try service.applyAnalysisResult(result, to: queuedRecord.record)

                latestAIExplanation = AIExplanationPreview(
                    rawText: queuedRecord.record.rawText,
                    sentenceMeaning: result.sentenceMeaning,
                    candidates: result.candidates.map(AIExplanationCandidatePreview.init(candidate:))
                )
                statusMessage = "Analyzed \(queuedRecord.record.rawText). Candidates: \(candidates.count)"
                errorMessage = nil
            } catch {
                if queuedRecord.record.status != .failed {
                    try? service.markFailed(queuedRecord.record, summary: error.localizedDescription)
                }
                statusMessage = nil
                errorMessage = "Analysis failed for \(queuedRecord.record.rawText): \(error.localizedDescription)"
            }

            isProcessingAnalysisQueue = false
            activeAnalysisTitle = nil
            processNextQueuedAnalysisIfNeeded()
        }
    }
}

private struct QueuedAnalysisRecord: Identifiable {
    let id = UUID()
    let record: InputRecordModel
    let courseName: String?
}

private struct AIExplanationPreview {
    let rawText: String
    let sentenceMeaning: String?
    let candidates: [AIExplanationCandidatePreview]

    init(
        rawText: String,
        sentenceMeaning: String?,
        candidates: [AIExplanationCandidatePreview]
    ) {
        self.rawText = rawText
        self.sentenceMeaning = Self.nonBlank(sentenceMeaning)
        self.candidates = candidates
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return TextNormalizer.isBlank(trimmed) ? nil : trimmed
    }
}

private struct AIExplanationCandidatePreview: Identifiable {
    let id: String
    let term: String
    let importance: Importance
    let chineseMeaning: String?
    let aiContextExplanation: String?

    init(candidate: AIAnalysisCandidate) {
        id = "\(TextNormalizer.normalized(candidate.term))-\(candidate.termType.rawValue)-\(candidate.importance.rawValue)"
        term = candidate.term
        importance = candidate.importance
        chineseMeaning = Self.nonBlank(candidate.chineseMeaning)
        aiContextExplanation = Self.nonBlank(candidate.aiContextExplanation)
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return TextNormalizer.isBlank(trimmed) ? nil : trimmed
    }
}
