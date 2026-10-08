#if WORDNOTE_V2_VALIDATION
import SwiftUI
import WordNoteCore

struct V2VocabularyFilters: View {
    @Binding var query: VocabularyBrowseQuery
    let courses: [CourseModel]
    let tags: [WordNoteTags.Option]
    let visibleCount: Int
    let totalCount: Int
    let selectedCount: Int
    let allSelected: Bool
    let onSelectAll: () -> Void
    let onOrganize: () -> Void
    let onExport: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Vocabulary").font(WordNoteTheme.editorialFont(size: 25, weight: .semibold))
                Spacer()
                Menu {
                    Button("Export Filtered (\(visibleCount))", systemImage: "square.and.arrow.up") { onExport(false) }
                    Button("Export Selected", systemImage: "doc") { onExport(true) }
                } label: { Image(systemName: "square.and.arrow.up") }
                .help("Export vocabulary as CSV").accessibilityLabel("Export vocabulary as CSV").disabled(visibleCount == 0)
            }
            Text("\(visibleCount) / \(totalCount) terms").font(.caption).foregroundStyle(.secondary)
            TextField("Search English or Chinese meanings", text: $query.text).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Course", selection: $query.courseID) {
                    Text("All courses").tag(UUID?.none)
                    ForEach(courses.sorted { $0.courseName < $1.courseName }, id: \.id) { Text($0.courseName).tag(Optional($0.id)) }
                    if let id = query.courseID, !courses.contains(where: { $0.id == id }) {
                        Text("Unavailable course").tag(Optional(id))
                    }
                }.labelsHidden().help("Course filter")
                Picker("Mastery", selection: $query.mastery) {
                    Text("All mastery").tag(MasteryLevel?.none)
                    ForEach(MasteryLevel.allCases) { Text($0.displayTitle).tag(Optional($0)) }
                }.labelsHidden().help("Mastery filter")
            }
            HStack {
                Picker("Tag", selection: $query.tag) {
                    Text("All tags").tag(String?.none)
                    ForEach(tags) { Text($0.label).tag(Optional($0.id)) }
                    if let key = query.tag, !tags.contains(where: { $0.id == key }) { Text(key).tag(Optional(key)) }
                }.labelsHidden().help("Tag filter")
                Picker("Activity", selection: $query.activity) {
                    ForEach(VocabularyActivity.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().help("Recorded repeat lookups")
            }
            Picker("Sort", selection: $query.sort) {
                ForEach(VocabularySort.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                Button(allSelected ? "Clear Selection" : "Select All", systemImage: "checklist", action: onSelectAll)
                    .labelStyle(.iconOnly).help(allSelected ? "Clear selection" : "Select all visible terms").disabled(visibleCount == 0)
                Text("\(selectedCount) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Organize", systemImage: "tag", action: onOrganize).disabled(selectedCount == 0)
            }
        }.padding(16)
    }
}
#endif
