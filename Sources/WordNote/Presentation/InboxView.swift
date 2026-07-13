import SwiftData
import SwiftUI
import WordNoteCore

struct InboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var storedRecords: [InputRecordModel]
    @Query private var storedCourses: [CourseModel]
    @Query private var storedCandidates: [CandidateTermModel]

    @State private var selectedRecordID: UUID?
    @State private var selectedBatchRecordIDs = Set<UUID>()
    @State private var errorMessage: String?
    @State private var analyzingRecordID: UUID?
    @SceneStorage("inboxConfirmedRecordsExpanded") private var confirmedRecordsExpanded = false

    private var records: [InputRecordModel] {
        storedRecords.sorted { $0.createdAt > $1.createdAt }
    }

    private var courses: [CourseModel] {
        storedCourses.sorted { $0.courseName.localizedStandardCompare($1.courseName) == .orderedAscending }
    }

    private var candidates: [CandidateTermModel] {
        storedCandidates.sorted { $0.createdAt < $1.createdAt }
    }

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

    private var confirmableRecords: [InputRecordModel] {
        activeRecords.filter { record in
            record.status == .analyzed && !pendingCandidates(for: record).isEmpty
        }
    }

    private var confirmableRecordIDs: Set<UUID> {
        Set(confirmableRecords.map(\.id))
    }

    private var allConfirmableRecordsSelected: Bool {
        !confirmableRecordIDs.isEmpty && confirmableRecordIDs.isSubset(of: selectedBatchRecordIDs)
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
        .onAppear {
            maintainSelection()
            pruneBatchSelection()
        }
        .onChange(of: selectableRecords.map(\.id)) {
            maintainSelection()
        }
        .onChange(of: visibleRecordCount) {
            maintainSelection()
        }
        .onChange(of: confirmedRecordsExpanded) {
            maintainSelection()
        }
        .onChange(of: confirmableRecordIDs) {
            pruneBatchSelection()
        }
    }

    private var recordList: some View {
        List(selection: $selectedRecordID) {
            if !activeRecords.isEmpty {
                Section("Needs Review") {
                    ForEach(activeRecords, id: \.id) { record in
                        InboxRow(
                            record: record,
                            previewText: previewText(for: record),
                            batchSelection: batchSelectionBinding(for: record),
                            batchSelectionEnabled: confirmableRecordIDs.contains(record.id)
                        )
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
                                previewText: previewText(for: record),
                                batchSelection: nil,
                                batchSelectionEnabled: false,
                                isConfirmed: true
                            )
                            .tag(record.id)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            PageHeader(
                title: "Inbox",
                subtitle: "\(activeRecords.count) active, \(confirmedRecords.count) confirmed"
            ) {
                HStack(spacing: 8) {
                    Button {
                        toggleSelectAllConfirmableRecords()
                    } label: {
                        Label(allConfirmableRecordsSelected ? "Clear" : "Select All", systemImage: "checklist")
                    }
                    .disabled(confirmableRecords.isEmpty)

                    Button {
                        confirmSelectedRecords()
                    } label: {
                        Label("Confirm Selected", systemImage: "checkmark.circle")
                    }
                    .disabled(selectedBatchRecordIDs.isEmpty)
                }
            }
            .padding(18)
            .background(WordNoteTheme.surface)
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
        .background(WordNoteTheme.surface)
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

    private func candidates(for record: InputRecordModel) -> [CandidateTermModel] {
        candidates.filter { $0.inputRecordID == record.id }
    }

    private func pendingCandidates(for record: InputRecordModel) -> [CandidateTermModel] {
        candidates(for: record).filter { $0.status == .pending }
    }

    private func previewText(for record: InputRecordModel) -> String {
        let lookupDirection = LookupDirectionDetector.detect(record.rawText)
        let preview: String?
        switch lookupDirection {
        case .englishToChinese:
            preview = candidates(for: record)
                .compactMap { normalizedPreviewText($0.chineseMeaning) }
                .first ?? normalizedPreviewText(record.sentenceMeaning)
        case .chineseToEnglish:
            preview = candidates(for: record)
                .compactMap { normalizedPreviewText($0.term) }
                .first ?? normalizedPreviewText(record.sentenceMeaning)
        }

        guard let preview else { return record.status.displayTitle }
        return String(preview.prefix(18))
    }

    private func normalizedPreviewText(_ value: String?) -> String? {
        let trimmed = value?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func batchSelectionBinding(for record: InputRecordModel) -> Binding<Bool>? {
        guard confirmableRecordIDs.contains(record.id) else { return nil }

        return Binding(
            get: { selectedBatchRecordIDs.contains(record.id) },
            set: { isSelected in
                if isSelected {
                    selectedBatchRecordIDs.insert(record.id)
                } else {
                    selectedBatchRecordIDs.remove(record.id)
                }
            }
        )
    }

    private func toggleSelectAllConfirmableRecords() {
        if allConfirmableRecordsSelected {
            selectedBatchRecordIDs.subtract(confirmableRecordIDs)
        } else {
            selectedBatchRecordIDs.formUnion(confirmableRecordIDs)
        }
    }

    private func confirmSelectedRecords() {
        let recordsToConfirm = confirmableRecords
            .filter { selectedBatchRecordIDs.contains($0.id) }
            .map { record in
                (record: record, candidates: pendingCandidates(for: record))
            }

        guard !recordsToConfirm.isEmpty else { return }

        let service = VocabularyService(modelContext: modelContext)

        do {
            _ = try service.confirmCandidates(
                recordsToConfirm.map {
                    CandidateConfirmation(candidates: $0.candidates, sourceRecord: $0.record)
                }
            )
            selectedBatchRecordIDs.subtract(recordsToConfirm.map(\.record.id))
            errorMessage = nil
            maintainSelection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pruneBatchSelection() {
        selectedBatchRecordIDs.formIntersection(confirmableRecordIDs)
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
