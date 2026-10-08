#if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
import SwiftUI
import WordNoteCore

struct V2CandidateReadingRow: View {
    let value: WordNoteV2CandidateEdit
    @Binding var isSelected: Bool
    let hasExistingTerm: Bool
    let onEdit: () -> Void
    let onConfirm: () -> Void
    let onIgnore: () -> Void
    @State private var detailsExpanded = false

    private var details: [(String, String)] {
        [("English", value.englishDefinition), ("Technical Meaning", value.aiContextExplanation), ("Example", value.exampleSentence)]
            .filter { !TextNormalizer.isBlank($0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Toggle("Select \(value.term)", isOn: $isSelected).labelsHidden().toggleStyle(.checkbox).padding(.top, 3)
                Text(value.term).font(.system(size: 18, weight: .semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                Button("Edit", systemImage: "pencil", action: onEdit).labelStyle(.iconOnly).help("Edit candidate")
            }
            Text(TextNormalizer.isBlank(value.chineseMeaning) ? value.englishDefinition : value.chineseMeaning)
                .font(.system(size: 15)).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !LookupDirectionDetector.isEnglishVocabularyTerm(value.term) {
                Label("English headword required", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(WordNoteTheme.amber)
            }
            if !details.isEmpty {
                DisclosureGroup("Details", isExpanded: $detailsExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(details, id: \.0) { title, text in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(text).textSelection(.enabled).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.padding(.top, 8)
                }
            }
            HStack {
                Button(hasExistingTerm ? "Link" : "Save", systemImage: hasExistingTerm ? "link" : "checkmark", action: onConfirm)
                    .help(hasExistingTerm ? "Preview existing matches before linking" : "Preview and save candidate")
                Button("Ignore", systemImage: "archivebox", action: onIgnore).labelStyle(.iconOnly).help("Ignore candidate")
                Spacer()
                Text(value.importance.displayTitle).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6)
    }
}
#endif
