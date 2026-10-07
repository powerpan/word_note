import SwiftData
import SwiftUI
import WordNoteCore

struct ManualTermEditor: View {
    @Environment(\.modelContext) private var modelContext

    let record: InputRecordModel
    let onSaved: (TermModel) -> Void
    let onCancel: () -> Void

    @State private var termText: String
    @State private var chineseMeaning = ""
    @State private var englishDefinition = ""
    @State private var errorMessage: String?
    @State private var editRevision: Int

    init(
        record: InputRecordModel,
        onSaved: @escaping (TermModel) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.record = record
        self.onSaved = onSaved
        self.onCancel = onCancel
        _termText = State(initialValue: record.rawText)
        _editRevision = State(initialValue: record.editRevision)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manual Term")
                .font(.headline)

            TextField("Term", text: $termText)
            TextField("Chinese meaning", text: $chineseMeaning, axis: .vertical)
                .lineLimit(1...4)
            TextField("English definition", text: $englishDefinition, axis: .vertical)
                .lineLimit(1...4)

            if let errorMessage {
                StatusBanner(message: errorMessage, kind: .warning)
            }

            HStack {
                Button("Cancel", action: onCancel)
                Button {
                    save()
                } label: {
                    Label("Save Term", systemImage: "checkmark.circle")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    TextNormalizer.isBlank(termText)
                        || (TextNormalizer.isBlank(chineseMeaning) && TextNormalizer.isBlank(englishDefinition))
                )
            }
        }
        .padding(12)
        .wordNoteSurface(elevated: true)
    }

    private func save() {
        do {
            let term = try VocabularyService(modelContext: modelContext, expectedRevision: editRevision, courseIDs: []).createManualTerm(
                termText: termText,
                chineseMeaning: chineseMeaning,
                englishDefinition: englishDefinition,
                sourceRecord: record
            )
            errorMessage = nil
            onSaved(term)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
