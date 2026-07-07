import SwiftData
import SwiftUI
import WordNoteCore

struct QuickAddView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CourseModel.courseName) private var courses: [CourseModel]

    @State private var rawText = ""
    @State private var selectedCourseID: UUID?
    @State private var selectedSourceType: SourceType = .other
    @State private var note = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var isAnalyzing = false

    private var canSave: Bool {
        !TextNormalizer.isBlank(rawText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            VStack(alignment: .leading, spacing: 14) {
                TextEditor(text: $rawText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180)
                    .padding(10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        if rawText.isEmpty {
                            Text("Paste a word, phrase, or sentence from class, paper, or slides")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }

                HStack(spacing: 12) {
                    Picker("Course", selection: $selectedCourseID) {
                        Text("No Course").tag(UUID?.none)
                        ForEach(courses, id: \.id) { course in
                            Text(course.courseName).tag(Optional(course.id))
                        }
                    }
                    .frame(maxWidth: 260)

                    Picker("Source", selection: $selectedSourceType) {
                        ForEach(SourceType.allCases) { sourceType in
                            Text(sourceType.displayTitle).tag(sourceType)
                        }
                    }
                    .frame(maxWidth: 220)
                }

                TextField("Note", text: $note, axis: .vertical)
                    .lineLimit(2...4)
            }

            HStack {
                Button("Save") {
                    saveDraft()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canSave)

                Button("Save & Analyze") {
                    saveAndAnalyze()
                }
                .disabled(!canSave || isAnalyzing)

                Spacer()
            }

            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            if isAnalyzing {
                ProgressView("Analyzing with DeepSeek...")
            }

            Spacer()
        }
        .padding(28)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick Add")
                .font(.largeTitle.bold())
            Text("Save raw English input, or analyze it with DeepSeek to generate candidate terms.")
                .foregroundStyle(.secondary)
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
        isAnalyzing = true
        statusMessage = nil
        errorMessage = nil

        Task { @MainActor in
            let service = InputRecordService(modelContext: modelContext)
            var record: InputRecordModel?

            do {
                let createdRecord = try service.createAnalyzing(
                    rawText: rawText,
                    courseID: selectedCourseID,
                    sourceType: selectedSourceType,
                    note: note
                )
                record = createdRecord

                guard let apiKey = DeepSeekAPIKeyResolver.resolve() else {
                    try service.markFailed(createdRecord, summary: AIAnalysisError.missingAPIKey.localizedDescription)
                    throw AIAnalysisError.missingAPIKey
                }

                let courseName = courses.first { $0.id == selectedCourseID }?.courseName
                let analysisService = AIAnalysisService(
                    client: DeepSeekChatClient(apiKey: apiKey)
                )
                let result = try await analysisService.analyze(
                    AIAnalysisRequest(
                        rawText: createdRecord.rawText,
                        courseName: courseName,
                        sourceType: createdRecord.sourceType,
                        userNote: createdRecord.note
                    )
                )
                let candidates = try service.applyAnalysisResult(result, to: createdRecord)

                rawText = ""
                note = ""
                statusMessage = "Analyzed \(createdRecord.rawText). Candidates: \(candidates.count)"
            } catch {
                if let record, record.status != .failed {
                    try? service.markFailed(record, summary: error.localizedDescription)
                }
                errorMessage = error.localizedDescription
            }

            isAnalyzing = false
        }
    }
}
