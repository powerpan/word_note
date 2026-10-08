#if WORDNOTE_V3_VALIDATION
import SwiftUI
import WordNoteCore

struct V3VocabularyCardFilters: View {
    @Binding var query: VocabularyCardQuery
    var body: some View {
        VStack(spacing: 8) {
            Picker("Card direction", selection: $query.mode) {
                Text("All directions").tag(ReviewMode?.none)
                ForEach(ReviewMode.allCases) { Text(AppLocalization.text($0.displayTitle)).tag(Optional($0)) }
            }
            HStack {
                Picker("Card mastery", selection: $query.mastery) {
                    Text("All mastery").tag(MasteryLevel?.none)
                    ForEach(MasteryLevel.allCases) { Text(AppLocalization.text($0.displayTitle)).tag(Optional($0)) }
                }.labelsHidden().help("Card mastery")
                Picker("Card state", selection: $query.state) {
                    Text("All states").tag(ReviewCardBrowseState?.none)
                    ForEach(ReviewCardBrowseState.allCases) { Text(AppLocalization.text($0.title)).tag(Optional($0)) }
                }.labelsHidden().help("Card state")
                if query.isActive {
                    Button("Clear card filters", systemImage: "xmark.circle") { query = .init() }
                        .labelStyle(.iconOnly).help("Clear card filters")
                }
            }
        }
    }
}
#endif
