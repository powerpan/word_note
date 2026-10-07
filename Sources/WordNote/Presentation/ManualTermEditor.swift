import SwiftData
import SwiftUI
import WordNoteCore

struct ManualTermEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.editProtection) private var editProtection

    let record: InputRecordModel
    let onSaved: (TermModel) -> Void
    let onCancel: () -> Void

    @State private var values: WordNoteEditDraft<ManualTermValues>
    private var draft: ManualTermValues { get { values.value } nonmutating set { values.value = newValue } }
    private var original: ManualTermValues { get { values.baseline } nonmutating set { values.baseline = newValue } }
    @State private var draftID = UUID()
    @State private var errorMessage: String?

    init(
        record: InputRecordModel,
        onSaved: @escaping (TermModel) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.record = record
        self.onSaved = onSaved
        self.onCancel = onCancel
        let value = ManualTermValues(termText: record.rawText)
        _values = State(initialValue: WordNoteEditDraft(value, revision: record.editRevision))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manual Term")
                .font(.headline)

            TextField("Term", text: $values.value.termText)
            TextField("Chinese meaning", text: $values.value.chineseMeaning, axis: .vertical)
                .lineLimit(1...4)
            TextField("English definition", text: $values.value.englishDefinition, axis: .vertical)
                .lineLimit(1...4)

            if let errorMessage {
                StatusBanner(message: errorMessage, kind: .warning)
            }

            HStack {
                Button("Cancel") { protectingEdits(editProtection, perform: onCancel) }
                Button {
                    save()
                } label: {
                    Label("Save Term", systemImage: "checkmark.circle")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    TextNormalizer.isBlank(draft.termText)
                        || (TextNormalizer.isBlank(draft.chineseMeaning) && TextNormalizer.isBlank(draft.englishDefinition))
                )
            }
        }
        .padding(12)
        .wordNoteSurface(elevated: true)
        .protectEdits(id: draftID, value: draft, isDirty: { values.isDirty }, title: "Manual Term", preview: { values.value.preview },
                      save: capturedSave, discard: discardDraft)
    }

    private func save() {
        do {
            try capturedSave()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var capturedSave: () throws -> Void {
        let id = record.id
        return {
            let value = values.value
            let revision = values.revision
            guard let current = try modelContext.fetch(FetchDescriptor<InputRecordModel>()).first(where: { $0.id == id }) else {
                throw WordNoteV2ContentError.missingEntity
            }
            let term = try VocabularyService(modelContext: modelContext, expectedRevision: revision, courseIDs: []).createManualTerm(
                termText: value.termText,
                chineseMeaning: value.chineseMeaning,
                englishDefinition: value.englishDefinition,
                sourceRecord: current
            )
            original = value
            errorMessage = nil
            onSaved(term)
        }
    }

    private func discardDraft() {
        draft = original
        errorMessage = nil
    }
}

private struct ManualTermValues: Equatable {
    var termText: String
    var chineseMeaning = ""
    var englishDefinition = ""
    var preview: String { [termText, chineseMeaning, englishDefinition].filter { !$0.isEmpty }.joined(separator: "\n") }
}
