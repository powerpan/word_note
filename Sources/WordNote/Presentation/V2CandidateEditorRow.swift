#if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
import SwiftData
import SwiftUI
import WordNoteCore

struct V2CandidateEditorRow: View {
    @Binding var draft: WordNoteV2CandidateEdit
    @Binding var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Select \(draft.term)", isOn: $isSelected).labelsHidden().toggleStyle(.checkbox)
                TextField("Term", text: $draft.term).font(.headline)
                Picker("Importance", selection: $draft.importance) {
                    ForEach(Importance.allCases) { Text(AppLocalization.text($0.displayTitle)).tag($0) }
                }.labelsHidden().frame(width: 120)
                Picker("Category", selection: $draft.category) {
                    ForEach(TermCategory.allCases) { Text(AppLocalization.text($0.displayTitle)).tag($0) }
                }.labelsHidden().frame(width: 150)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow { Text("Chinese").foregroundStyle(.secondary); TextField("Chinese meaning", text: $draft.chineseMeaning, axis: .vertical).lineLimit(1...4) }
                GridRow { Text("English").foregroundStyle(.secondary); TextField("English definition", text: $draft.englishDefinition, axis: .vertical).lineLimit(1...4) }
                GridRow { Text("Context").foregroundStyle(.secondary); TextField("AI / CS context explanation", text: $draft.aiContextExplanation, axis: .vertical).lineLimit(1...4) }
                GridRow { Text("Example").foregroundStyle(.secondary); TextField("Example sentence", text: $draft.exampleSentence, axis: .vertical).lineLimit(1...4) }
            }
        }
        .padding(12)
        .wordNoteSurface(elevated: true)
    }
}
#endif
