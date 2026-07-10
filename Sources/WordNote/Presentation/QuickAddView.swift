import SwiftData
import SwiftUI
import WordNoteCore

struct QuickAddView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(QuickAddAnalysisQueue.self) private var analysisQueue
    @AppStorage("defaultSourceType") private var defaultSourceType = SourceType.other.rawValue
    @Query private var storedCourses: [CourseModel]

    @State private var rawText = ""
    @State private var selectedCourseID: UUID?
    @State private var selectedSourceType: SourceType = .other
    @State private var note = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var courses: [CourseModel] {
        storedCourses.sorted { $0.courseName.localizedStandardCompare($1.courseName) == .orderedAscending }
    }

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
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
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
        statusMessage = nil
        errorMessage = nil

        do {
            let courseName = courses.first { $0.id == selectedCourseID }?.courseName
            try analysisQueue.enqueue(
                rawText: rawText,
                courseID: selectedCourseID,
                courseName: courseName,
                sourceType: selectedSourceType,
                note: note
            )

            rawText = ""
            note = ""
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func applyDefaultSourceType() {
        selectedSourceType = SourceType(rawValue: defaultSourceType) ?? .other
    }

    @ViewBuilder
    private var aiExplanationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI 釋義產出後展示")
                .font(.headline)

            if let latestAIExplanation = analysisQueue.latestAIExplanation {
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
}
