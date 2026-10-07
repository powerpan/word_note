import SwiftUI
import WordNoteCore

struct InboxRow: View {
    let record: InputRecordModel
    let previewText: String
    let batchSelection: Binding<Bool>?
    let batchSelectionEnabled: Bool
    var isConfirmed = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.rawText)
                    .lineLimit(1)
                    .font(.headline)
                Text(previewText)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let batchSelection {
                Toggle("", isOn: batchSelection)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!batchSelectionEnabled)
                    .help(batchSelectionEnabled ? "Select for batch confirmation" : "Analyze this record before batch confirmation")
                    .accessibilityLabel("Select \(record.rawText) for batch confirmation")
            } else if isConfirmed {
                Image(systemName: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Confirmed")
            }
        }
        .opacity(isConfirmed ? 0.72 : 1)
        .padding(.vertical, 4)
    }
}

struct InputRecordDetailView: View {
    let record: InputRecordModel
    let courseName: String?
    let candidates: [CandidateTermModel]
    let isAnalyzing: Bool
    @Binding var errorMessage: String?
    let onAnalyze: (InputRecordModel) -> Void
    let onIgnore: (InputRecordModel) -> Void
    let onDelete: (InputRecordModel) -> Void

    @State private var isDeleteConfirmationPresented = false

    private var lookupDirection: LookupDirection {
        record.resolvedDirection
    }

    private var sentenceMeaningTitle: String {
        lookupDirection == .chineseToEnglish ? "English Rendering" : "Sentence Meaning"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "Input Record",
                    subtitle: "\(record.sourceType.displayTitle) - \(lookupDirection.displayTitle)"
                ) {
                    Button {
                        onAnalyze(record)
                    } label: {
                        Label(record.analysisFailed ? "Retry" : "Analyze", systemImage: "sparkles")
                    }
                    .disabled(isAnalyzing || record.analysisPending || record.status == .completed)

                    Button {
                        onIgnore(record)
                    } label: {
                        Label("Ignore", systemImage: "archivebox")
                    }

                    Button(role: .destructive) {
                        isDeleteConfirmationPresented = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .confirmationDialog(
                        "Delete this input record?",
                        isPresented: $isDeleteConfirmationPresented
                    ) {
                        Button("Delete Input Record", role: .destructive) {
                            onDelete(record)
                        }
                    } message: {
                        Text("Its AI candidates will also be deleted. Saved vocabulary terms will be kept.")
                    }
                }

                if let errorMessage {
                    StatusBanner(message: errorMessage, kind: .warning)
                }
                if isAnalyzing || record.analysisPending {
                    ProgressView("Analyzing with DeepSeek...")
                }

                GroupBox("Raw Text") {
                    Text(record.rawText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    detailRow("Status", record.visibleStatusTitle)
                    detailRow("Source", record.sourceType.displayTitle)
                    detailRow("Course", courseName ?? "No Course")
                    detailRow("Created", record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    detailRow("Updated", record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }

                optionalTextGroup("Note", value: record.note)
                optionalTextGroup(sentenceMeaningTitle, value: record.sentenceMeaning)
                optionalTextGroup("AI Error", value: record.aiErrorSummary)

                if !candidates.isEmpty || [.draft, .analyzed, .failed].contains(record.status) {
                    CandidateReviewView(record: record, candidates: candidates)
                        .id(record.id)
                        .disabled(record.analysisPending)
                }

                Spacer(minLength: 0)
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .groupBoxStyle(WordNoteGroupBoxStyle())
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

    @ViewBuilder
    private func optionalTextGroup(_ title: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            GroupBox(title) {
                Text(value)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }
        }
    }
}
