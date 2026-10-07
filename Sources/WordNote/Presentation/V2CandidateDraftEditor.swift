#if WORDNOTE_V2_VALIDATION
import SwiftData
import SwiftUI
import WordNoteCore

struct V2CandidateDraftEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.savedChangeHistory) private var undoHistory
    let candidates: [CandidateTermModel]
    let record: InputRecordModel
    @Binding var selectedIDs: Set<UUID>
    @Binding var editedIDs: Set<UUID>
    @State private var draftID = UUID()
    @State private var values: WordNoteEditDraft<[WordNoteV2CandidateEdit]>
    private var drafts: [WordNoteV2CandidateEdit] { get { values.value } nonmutating set { values.value = newValue } }
    private var original: [WordNoteV2CandidateEdit] { get { values.baseline } nonmutating set { values.baseline = newValue } }
    @State private var errorMessage: String?

    init(candidates: [CandidateTermModel], record: InputRecordModel, selectedIDs: Binding<Set<UUID>>, editedIDs: Binding<Set<UUID>>) {
        self.candidates = candidates
        self.record = record
        _selectedIDs = selectedIDs
        _editedIDs = editedIDs
        let values = candidates.map { WordNoteV2CandidateEdit($0, recordRevision: record.revision) }
        _values = State(initialValue: WordNoteEditDraft(values, revision: record.revision))
    }

    private var current: [WordNoteV2CandidateEdit] { candidates.map { WordNoteV2CandidateEdit($0, recordRevision: record.revision) } }
    private var changed: [WordNoteV2CandidateEdit] { drafts.filter { edit in original.first(where: { $0.id == edit.id }) != edit } }
    private var isDirty: Bool { drafts != original }
    private var hasConflict: Bool {
        Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0) }) != Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($values.value, id: \.id) { $draft in
                V2CandidateEditorRow(draft: $draft, isSelected: Binding(
                    get: { selectedIDs.contains(draft.id) },
                    set: { if $0 { selectedIDs.insert(draft.id) } else { selectedIDs.remove(draft.id) } }
                ))
            }
            if isDirty {
                HStack {
                    Label("Unsaved changes", systemImage: "pencil.circle").foregroundStyle(.secondary)
                    Spacer()
                    Button("Discard", action: reload)
                    Button("Save Edits", systemImage: "checkmark") {
                        do { try capturedSave() } catch { errorMessage = error.localizedDescription }
                    }
                }
                if hasConflict {
                    DraftConflictView(draft: values, fields: WordNoteV2CandidateEdit.comparisonFields(for: original), loadCurrent: {
                        try WordNoteV2ContentService(container: context.container)
                            .candidateDraftVersion(original.map(\.id), sourceRecordID: record.id)
                    }, onApplied: { errorMessage = nil; editedIDs = Set(changed.map(\.id)) })
                }
            }
            if let errorMessage { StatusBanner(message: errorMessage, kind: .warning) }
        }
        .onChange(of: drafts) { editedIDs = Set(changed.map(\.id)) }
        .onChange(of: current) { if !isDirty { reload() } }
        .protectEdits(id: draftID, value: drafts, isDirty: { values.isDirty }, title: "Inbox candidates", preview: { preview },
                      save: capturedSave, discard: discardDraft)
    }

    private var preview: String {
        changed.map { [$0.term, $0.chineseMeaning, $0.englishDefinition, $0.aiContextExplanation, $0.exampleSentence]
            .filter { !$0.isEmpty }.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    private var capturedSave: () throws -> Void {
        return {
            try WordNoteV2ContentService(container: context.container, undoHistory: undoHistory).updateCandidates(changed)
            reload()
        }
    }

    private func reload() {
        drafts = current
        original = current
        values.revision = record.revision
        errorMessage = nil
        editedIDs = []
    }

    private func discardDraft() {
        drafts = original
        editedIDs = []
        errorMessage = nil
    }
}
#endif
