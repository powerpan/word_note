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
    @State private var isAnalyzing = false

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
                        .disabled(!canSave || isAnalyzing)

                        Button {
                            saveDraft()
                        } label: {
                            Label("Save Draft", systemImage: "tray.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(!canSave)

                        if isAnalyzing {
                            ProgressView("Analyzing with DeepSeek...")
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

    private func applyDefaultSourceType() {
        selectedSourceType = SourceType(rawValue: defaultSourceType) ?? .other
    }
}
