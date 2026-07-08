import SwiftData
import SwiftUI
import WordNoteCore

struct InboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \InputRecordModel.createdAt, order: .reverse) private var records: [InputRecordModel]
    @Query(sort: \CourseModel.courseName) private var courses: [CourseModel]
    @Query(sort: \CandidateTermModel.createdAt) private var candidates: [CandidateTermModel]

    @State private var selectedRecordID: UUID?
    @State private var errorMessage: String?
    @State private var analyzingRecordID: UUID?
    @SceneStorage("inboxConfirmedRecordsExpanded") private var confirmedRecordsExpanded = false

    private var activeRecords: [InputRecordModel] {
        records.filter { record in
            record.status != .ignored && record.status != .analyzing && record.status != .completed
        }
    }

    private var confirmedRecords: [InputRecordModel] {
        records.filter { $0.status == .completed }
    }

    private var selectableRecords: [InputRecordModel] {
        activeRecords + confirmedRecords
    }

    private var visibleRecordCount: Int {
        activeRecords.count + (confirmedRecordsExpanded ? confirmedRecords.count : 0)
    }

    private var selectedRecord: InputRecordModel? {
        guard let selectedRecordID else { return nil }
        return selectableRecords.first { $0.id == selectedRecordID }
    }

    var body: some View {
        GeometryReader { proxy in
            let listWidth = InboxLayoutMetrics.listWidth(for: proxy.size.width)

            HStack(spacing: 0) {
                recordList
                    .frame(
                        minWidth: InboxLayoutMetrics.minListWidth,
                        idealWidth: listWidth,
                        maxWidth: listWidth
                    )
                    .layoutPriority(1)

                Divider()

                detailPane
                    .frame(minWidth: InboxLayoutMetrics.minDetailWidth)
                    .layoutPriority(2)
            }
        }
        .frame(minWidth: InboxLayoutMetrics.minContentWidth, minHeight: InboxLayoutMetrics.minContentHeight)
        .onAppear(perform: maintainSelection)
        .onChange(of: selectableRecords.map(\.id)) {
            maintainSelection()
        }
        .onChange(of: visibleRecordCount) {
            maintainSelection()
        }
        .onChange(of: confirmedRecordsExpanded) {
            maintainSelection()
        }
    }

    private var recordList: some View {
        List(selection: $selectedRecordID) {
            if !activeRecords.isEmpty {
                Section("Needs Review") {
                    ForEach(activeRecords, id: \.id) { record in
                        InboxRow(record: record, courseName: courseName(for: record.courseID))
                            .tag(record.id)
                    }
                }
            }

            if !confirmedRecords.isEmpty {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: confirmedRecordsExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        Label("Confirmed", systemImage: "checkmark.circle")
                        Spacer()
                        Text(confirmedRecords.count, format: .number)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        confirmedRecordsExpanded.toggle()
                    }

                    if confirmedRecordsExpanded {
                        ForEach(confirmedRecords, id: \.id) { record in
                            InboxRow(
                                record: record,
                                courseName: courseName(for: record.courseID),
                                isConfirmed: true
                            )
                            .tag(record.id)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PageHeader(
                title: "Inbox",
                subtitle: "\(activeRecords.count) active, \(confirmedRecords.count) confirmed"
            ) {
                EmptyView()
            }
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            if selectableRecords.isEmpty {
                EmptyStateView(
                    systemImage: "tray",
                    title: "No Inbox Records",
                    message: "Use Quick Add to save a word, phrase, or sentence."
                ) {
                    EmptyView()
                }
                .allowsHitTesting(false)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selectedRecord {
            InputRecordDetailView(
                record: selectedRecord,
                courseName: courseName(for: selectedRecord.courseID),
                candidates: candidates.filter { $0.inputRecordID == selectedRecord.id },
                isAnalyzing: analyzingRecordID == selectedRecord.id,
                errorMessage: $errorMessage,
                onAnalyze: analyze,
                onIgnore: ignore,
                onDelete: delete
            )
        } else {
            EmptyStateView(
                systemImage: "doc.text",
                title: "No Record Selected",
                message: selectableRecords.isEmpty
                    ? "Saved input records will appear here."
                    : "Select an active record, or expand Confirmed to inspect handled records."
            ) {
                EmptyView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func courseName(for courseID: UUID?) -> String? {
        guard let courseID else { return nil }
        return courses.first { $0.id == courseID }?.courseName
    }

    private func ignore(_ record: InputRecordModel) {
        let service = InputRecordService(modelContext: modelContext)
        do {
            try service.ignore(record)
            if selectedRecordID == record.id {
                selectedRecordID = preferredSelectedRecord?.id
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ record: InputRecordModel) {
        let service = InputRecordService(modelContext: modelContext)
        do {
            try service.delete(record)
            selectedRecordID = preferredSelectedRecord?.id
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func analyze(_ record: InputRecordModel) {
        analyzingRecordID = record.id
        errorMessage = nil

        Task { @MainActor in
            let service = InputRecordService(modelContext: modelContext)

            do {
                guard let apiKey = DeepSeekAPIKeyResolver.resolve() else {
                    try service.markFailed(record, summary: AIAnalysisError.missingAPIKey.localizedDescription)
                    throw AIAnalysisError.missingAPIKey
                }

                try service.markAnalyzing(record)
                let analysisService = AIAnalysisService(client: DeepSeekChatClient(apiKey: apiKey))
                let result = try await analysisService.analyze(
                    AIAnalysisRequest(
                        rawText: record.rawText,
                        courseName: courseName(for: record.courseID),
                        sourceType: record.sourceType,
                        userNote: record.note
                    )
                )
                _ = try service.applyAnalysisResult(result, to: record)
            } catch {
                try? service.markFailed(record, summary: error.localizedDescription)
                errorMessage = error.localizedDescription
            }

            analyzingRecordID = nil
        }
    }

    private func maintainSelection() {
        if let selectedRecordID, visibleRecordsForSelection.contains(where: { $0.id == selectedRecordID }) {
            return
        }
        selectedRecordID = preferredSelectedRecord?.id
    }

    private var visibleRecordsForSelection: [InputRecordModel] {
        activeRecords + (confirmedRecordsExpanded ? confirmedRecords : [])
    }

    private var preferredSelectedRecord: InputRecordModel? {
        activeRecords.first ?? (confirmedRecordsExpanded ? confirmedRecords.first : nil)
    }
}

private enum InboxLayoutMetrics {
    static let minContentWidth: CGFloat = 900
    static let minContentHeight: CGFloat = 620
    static let minListWidth: CGFloat = 320
    static let maxListWidth: CGFloat = 420
    static let minDetailWidth: CGFloat = 560

    static func listWidth(for contentWidth: CGFloat) -> CGFloat {
        min(max(contentWidth * 0.36, minListWidth), maxListWidth)
    }
}

private struct InboxRow: View {
    let record: InputRecordModel
    let courseName: String?
    var isConfirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.rawText)
                .lineLimit(1)
                .font(.headline)

            HStack(spacing: 8) {
                if isConfirmed {
                    Label(record.status.displayTitle, systemImage: "checkmark.circle")
                } else {
                    Text(record.status.displayTitle)
                }
                Text(record.sourceType.displayTitle)
                if let courseName {
                    Text(courseName)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .opacity(isConfirmed ? 0.72 : 1)
        .padding(.vertical, 4)
    }
}

private struct InputRecordDetailView: View {
    let record: InputRecordModel
    let courseName: String?
    let candidates: [CandidateTermModel]
    let isAnalyzing: Bool
    @Binding var errorMessage: String?
    let onAnalyze: (InputRecordModel) -> Void
    let onIgnore: (InputRecordModel) -> Void
    let onDelete: (InputRecordModel) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "Input Record",
                    subtitle: record.sourceType.displayTitle
                ) {
                    Button {
                        onAnalyze(record)
                    } label: {
                        Label(record.status == .failed ? "Retry" : "Analyze", systemImage: "sparkles")
                    }
                    .disabled(isAnalyzing || record.status == .analyzing)

                    Button {
                        onIgnore(record)
                    } label: {
                        Label("Ignore", systemImage: "archivebox")
                    }

                    Button(role: .destructive) {
                        onDelete(record)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }

                if let errorMessage {
                    StatusBanner(message: errorMessage, kind: .warning)
                }

                if isAnalyzing || record.status == .analyzing {
                    ProgressView("Analyzing with DeepSeek...")
                }

                GroupBox("Raw Text") {
                    Text(record.rawText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    detailRow("Status", record.status.displayTitle)
                    detailRow("Source", record.sourceType.displayTitle)
                    detailRow("Course", courseName ?? "No Course")
                    detailRow("Created", record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    detailRow("Updated", record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }

                if let note = record.note, !note.isEmpty {
                    GroupBox("Note") {
                        Text(note)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    }
                }

                if let sentenceMeaning = record.sentenceMeaning, !sentenceMeaning.isEmpty {
                    GroupBox("Sentence Meaning") {
                        Text(sentenceMeaning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    }
                }

                if let aiErrorSummary = record.aiErrorSummary, !aiErrorSummary.isEmpty {
                    GroupBox("AI Error") {
                        Text(aiErrorSummary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    }
                }

                if !candidates.isEmpty {
                    CandidateReviewView(record: record, candidates: candidates)
                }

                Spacer(minLength: 0)
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func detailRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
