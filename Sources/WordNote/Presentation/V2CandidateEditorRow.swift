#if WORDNOTE_V2_VALIDATION
import SwiftData
import SwiftUI
import WordNoteCore

struct V2CandidateEditorRow: View {
    @Environment(\.modelContext) private var context
    let candidate: CandidateTermModel
    let record: InputRecordModel
    @Binding var isSelected: Bool
    let onDirtyChanged: (Bool) -> Void
    @State private var draft: WordNoteV2CandidateEdit
    @State private var original: WordNoteV2CandidateEdit
    @State private var errorMessage: String?

    init(candidate: CandidateTermModel, record: InputRecordModel, isSelected: Binding<Bool>, onDirtyChanged: @escaping (Bool) -> Void) {
        self.candidate = candidate
        self.record = record
        _isSelected = isSelected
        self.onDirtyChanged = onDirtyChanged
        let value = WordNoteV2CandidateEdit(candidate, recordRevision: record.revision)
        _draft = State(initialValue: value)
        _original = State(initialValue: value)
    }

    private var isDirty: Bool { draft != original }
    private var hasConflict: Bool { draft.revision != candidate.revision || draft.recordRevision != record.revision }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Select \(candidate.term)", isOn: $isSelected).labelsHidden().toggleStyle(.checkbox)
                TextField("Term", text: $draft.term).font(.headline)
                Picker("Importance", selection: $draft.importance) {
                    ForEach(Importance.allCases) { Text($0.displayTitle).tag($0) }
                }.labelsHidden().frame(width: 120)
                Picker("Category", selection: $draft.category) {
                    ForEach(TermCategory.allCases) { Text($0.displayTitle).tag($0) }
                }.labelsHidden().frame(width: 150)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow { Text("Chinese").foregroundStyle(.secondary); TextField("Chinese meaning", text: $draft.chineseMeaning, axis: .vertical).lineLimit(1...4) }
                GridRow { Text("English").foregroundStyle(.secondary); TextField("English definition", text: $draft.englishDefinition, axis: .vertical).lineLimit(1...4) }
                GridRow { Text("Context").foregroundStyle(.secondary); TextField("AI / CS context explanation", text: $draft.aiContextExplanation, axis: .vertical).lineLimit(1...4) }
                GridRow { Text("Example").foregroundStyle(.secondary); TextField("Example sentence", text: $draft.exampleSentence, axis: .vertical).lineLimit(1...4) }
            }
            if isDirty {
                HStack {
                    Label("Unsaved changes", systemImage: "pencil.circle").foregroundStyle(.secondary)
                    Spacer()
                    Button("Discard", action: reload)
                    Button("Save Edits", systemImage: "checkmark") { save() }.disabled(hasConflict)
                }
            }
            if hasConflict && isDirty {
                StatusBanner(message: "This record changed in another operation. Reload before saving.", kind: .warning)
            }
            if let errorMessage { StatusBanner(message: errorMessage, kind: .warning) }
        }
        .padding(12)
        .wordNoteSurface(elevated: true)
        .onChange(of: isDirty) { onDirtyChanged(isDirty) }
        .onChange(of: record.revision) { if !isDirty { reload() } }
        .onChange(of: candidate.revision) { if !isDirty { reload() } }
        .onDisappear { onDirtyChanged(false) }
    }

    private func reload() {
        let value = WordNoteV2CandidateEdit(candidate, recordRevision: record.revision)
        draft = value
        original = value
        errorMessage = nil
        onDirtyChanged(false)
    }

    private func save() {
        do {
            try WordNoteV2ContentService(container: context.container).updateCandidate(draft)
            reload()
        } catch { errorMessage = error.localizedDescription }
    }
}
#endif
