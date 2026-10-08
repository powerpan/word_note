import SwiftData
import SwiftUI
import WordNoteCore

struct CandidateReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.savedChangeHistory) private var undoHistory
    @Environment(\.editProtection) private var editProtection

    let record: InputRecordModel
    let candidates: [CandidateTermModel]

    @State private var selectedCandidateIDs = Set<UUID>()
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var isManualEditorPresented = false
    @State private var editedCandidateIDs = Set<UUID>()
    #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
    @State private var confirmationPlan: WordNoteV2ConfirmationPlan?
    #endif

    private var pendingCandidates: [CandidateTermModel] {
        candidates.filter { $0.status == .pending }
    }

    var body: some View {
        GroupBox("Candidate Review") {
            VStack(alignment: .leading, spacing: 14) {
                if pendingCandidates.isEmpty {
                    Label(
                        record.status == .completed
                            ? "All candidates have been handled."
                            : "No AI candidate is ready to save.",
                        systemImage: record.status == .completed ? "checkmark.circle" : "doc.badge.plus"
                    )
                        .foregroundStyle(.secondary)
                } else {
                    #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
                    V2CandidateDraftEditor(candidates: pendingCandidates, record: record,
                                           selectedIDs: $selectedCandidateIDs, editedIDs: $editedCandidateIDs)
                        .disabled(isManualEditorPresented)
                    #else
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
                    #endif

                    HStack {
                        Button {
                            protectingEdits(editProtection, perform: saveSelected)
                        } label: {
                            Label("Save Selected", systemImage: "checkmark.circle")
                        }
                        .disabled(selectedCandidateIDs.isEmpty || !editedCandidateIDs.isEmpty || isManualEditorPresented)

                        Button {
                            protectingEdits(editProtection, perform: ignoreSelected)
                        } label: {
                            Label("Ignore Selected", systemImage: "archivebox")
                        }
                        .disabled(selectedCandidateIDs.isEmpty || !editedCandidateIDs.isEmpty || isManualEditorPresented)

                        Button {
                            protectingEdits(editProtection, perform: ignoreAll)
                        } label: {
                            Label("Ignore All", systemImage: "xmark.circle")
                        }
                        .disabled(!editedCandidateIDs.isEmpty || isManualEditorPresented)

                        Button {
                            protectingEdits(editProtection) { isManualEditorPresented.toggle() }
                        } label: {
                            Label("Add Manually", systemImage: "square.and.pencil")
                        }

                        Spacer()
                    }
                }

                if record.status != .completed, pendingCandidates.isEmpty {
                    Button {
                        protectingEdits(editProtection) { isManualEditorPresented.toggle() }
                    } label: {
                        Label("Add Term Manually", systemImage: "square.and.pencil")
                    }
                }

                if isManualEditorPresented {
                    ManualTermEditor(
                        record: record,
                        onSaved: { term in
                            isManualEditorPresented = false
                            errorMessage = nil
                            statusMessage = "Saved \(term.term) to Vocabulary."
                        },
                        onCancel: { isManualEditorPresented = false }
                    )
                }

                if let statusMessage {
                    StatusBanner(message: statusMessage, kind: .success)
                }

                if let errorMessage {
                    StatusBanner(message: errorMessage, kind: .warning)
                }
            }
        }
        .groupBoxStyle(WordNoteGroupBoxStyle())
        .onAppear(perform: selectDefaultCandidates)
        .onChange(of: candidates.map(\.id)) {
            selectDefaultCandidates()
        }
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        .sheet(item: $confirmationPlan) { plan in
            V2ConfirmationPreview(plan: plan) { result in
                selectedCandidateIDs.removeAll()
                errorMessage = nil
                statusMessage = "Confirmed \(result.counts.candidates - result.counts.ignoredCandidates) candidates; ignored \(result.counts.ignoredCandidates)."
            }
        }
        #endif
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
        guard !selectedCandidates.isEmpty else { return }
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        do {
            confirmationPlan = try AppContentService(container: modelContext.container).makeConfirmationPlan(
                CandidateConfirmation(candidates: selectedCandidates, sourceRecord: record).selections
            )
            errorMessage = nil
            statusMessage = nil
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
        #else
        let service = VocabularyService(modelContext: modelContext, undoHistory: undoHistory)

        do {
            let terms = try service.createTerms(from: selectedCandidates, sourceRecord: record)
            selectedCandidateIDs.removeAll()
            errorMessage = nil
            statusMessage = "Saved \(terms.count) term\(terms.count == 1 ? "" : "s") to Vocabulary."
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
        #endif
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

#if !WORDNOTE_V2_VALIDATION && !WORDNOTE_V3_VALIDATION
private struct CandidateEditorRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var candidate: CandidateTermModel
    @Binding var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Toggle("", isOn: $isSelected)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Select \(candidate.term)")

                TextField("Term", text: guarded($candidate.term) { value in
                    candidate.normalizedTerm = TextNormalizer.normalized(value)
                })
                    .font(.headline)

                Picker("Importance", selection: guarded($candidate.importance)) {
                    ForEach(Importance.allCases) { importance in
                        Text(AppLocalization.text(importance.displayTitle)).tag(importance)
                    }
                }
                .labelsHidden()
                .frame(width: 120)

                Picker("Category", selection: guarded($candidate.category)) {
                    ForEach(TermCategory.allCases) { category in
                        Text(AppLocalization.text(category.displayTitle)).tag(category)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            if !TextNormalizer.isBlank(candidate.term),
               !LookupDirectionDetector.isEnglishVocabularyTerm(candidate.term) {
                Label("Use an English term; keep Chinese text in the meaning.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(WordNoteTheme.amber)
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
        .wordNoteSurface(elevated: true)
    }

    private func optionalBinding(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: {
                guard !WordNoteWriteGate.isBlocked(modelContext) else { return }
                binding.wrappedValue = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            }
        )
    }

    private func guarded<T>(_ binding: Binding<T>, onChange: @escaping (T) -> Void = { _ in }) -> Binding<T> {
        Binding(get: { binding.wrappedValue }, set: {
            guard !WordNoteWriteGate.isBlocked(modelContext) else { return }
            binding.wrappedValue = $0
            onChange($0)
        })
    }
}
#endif
