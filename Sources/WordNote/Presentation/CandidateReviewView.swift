import SwiftData
import SwiftUI
import WordNoteCore

struct CandidateReviewView: View {
    @Environment(\.modelContext) private var modelContext

    let record: InputRecordModel
    let candidates: [CandidateTermModel]

    @State private var selectedCandidateIDs = Set<UUID>()
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var pendingCandidates: [CandidateTermModel] {
        candidates.filter { $0.status == .pending }
    }

    var body: some View {
        GroupBox("Candidate Review") {
            VStack(alignment: .leading, spacing: 14) {
                if pendingCandidates.isEmpty {
                    Label("All candidates have been handled.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pendingCandidates, id: \.id) { candidate in
                        CandidateEditorRow(
                            candidate: candidate,
                            isSelected: Binding(
                                get: { selectedCandidateIDs.contains(candidate.id) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedCandidateIDs.insert(candidate.id)
                                    } else {
                                        selectedCandidateIDs.remove(candidate.id)
                                    }
                                }
                            )
                        )
                    }

                    HStack {
                        Button {
                            saveSelected()
                        } label: {
                            Label("Save Selected", systemImage: "checkmark.circle")
                        }
                        .disabled(selectedCandidateIDs.isEmpty)

                        Button {
                            ignoreSelected()
                        } label: {
                            Label("Ignore Selected", systemImage: "archivebox")
                        }
                        .disabled(selectedCandidateIDs.isEmpty)

                        Button {
                            ignoreAll()
                        } label: {
                            Label("Ignore All", systemImage: "xmark.circle")
                        }

                        Spacer()
                    }
                }

                if let statusMessage {
                    StatusBanner(message: statusMessage, kind: .success)
                }

                if let errorMessage {
                    StatusBanner(message: errorMessage, kind: .warning)
                }
            }
        }
        .onAppear(perform: selectDefaultCandidates)
        .onChange(of: candidates.map(\.id)) {
            selectDefaultCandidates()
        }
    }

    private func selectDefaultCandidates() {
        guard selectedCandidateIDs.isEmpty else { return }
        selectedCandidateIDs = Set(
            pendingCandidates
                .filter { $0.needToLearn && $0.importance != .low }
                .map(\.id)
        )
    }

    private func saveSelected() {
        let selectedCandidates = pendingCandidates.filter { selectedCandidateIDs.contains($0.id) }
        let service = VocabularyService(modelContext: modelContext)

        do {
            let terms = try service.createTerms(from: selectedCandidates, sourceRecord: record)
            selectedCandidateIDs.removeAll()
            errorMessage = nil
            statusMessage = "Saved \(terms.count) term\(terms.count == 1 ? "" : "s") to Vocabulary."
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func ignoreSelected() {
        let selectedCandidates = pendingCandidates.filter { selectedCandidateIDs.contains($0.id) }
        ignore(selectedCandidates)
    }

    private func ignoreAll() {
        ignore(pendingCandidates)
    }

    private func ignore(_ selectedCandidates: [CandidateTermModel]) {
        let service = VocabularyService(modelContext: modelContext)

        do {
            try service.ignore(selectedCandidates, sourceRecord: record)
            selectedCandidateIDs.removeAll()
            errorMessage = nil
            statusMessage = "Ignored \(selectedCandidates.count) candidate\(selectedCandidates.count == 1 ? "" : "s")."
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct CandidateEditorRow: View {
    @Bindable var candidate: CandidateTermModel
    @Binding var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Toggle("", isOn: $isSelected)
                    .labelsHidden()

                TextField("Term", text: $candidate.term)
                    .font(.headline)
                    .onChange(of: candidate.term) {
                        candidate.normalizedTerm = TextNormalizer.normalized(candidate.term)
                    }

                Picker("Importance", selection: $candidate.importance) {
                    ForEach(Importance.allCases) { importance in
                        Text(importance.displayTitle).tag(importance)
                    }
                }
                .labelsHidden()
                .frame(width: 120)

                Picker("Category", selection: $candidate.category) {
                    ForEach(TermCategory.allCases) { category in
                        Text(category.displayTitle).tag(category)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Chinese")
                        .foregroundStyle(.secondary)
                    TextField("Chinese meaning", text: optionalBinding($candidate.chineseMeaning), axis: .vertical)
                        .lineLimit(1...3)
                }
                GridRow {
                    Text("English")
                        .foregroundStyle(.secondary)
                    TextField("English definition", text: optionalBinding($candidate.englishDefinition), axis: .vertical)
                        .lineLimit(1...3)
                }
                GridRow {
                    Text("Context")
                        .foregroundStyle(.secondary)
                    TextField("AI / CS context explanation", text: optionalBinding($candidate.aiContextExplanation), axis: .vertical)
                        .lineLimit(1...4)
                }
                GridRow {
                    Text("Example")
                        .foregroundStyle(.secondary)
                    TextField("Example sentence", text: optionalBinding($candidate.exampleSentence), axis: .vertical)
                        .lineLimit(1...3)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func optionalBinding(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }
}
