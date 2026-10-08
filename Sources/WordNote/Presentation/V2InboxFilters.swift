#if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
import SwiftUI
import WordNoteCore

struct V2InboxFilters: View {
    @Binding var query: InboxBrowseQuery
    let courses: [CourseModel]
    let activeCount: Int
    let handledCount: Int
    let selectedCounts: (records: Int, candidates: Int)
    let allSelected: Bool
    let canSelect: Bool
    let onSelectAll: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Inbox").font(WordNoteTheme.editorialFont(size: 25, weight: .semibold))
                Spacer()
                Button(allSelected ? "Clear Selection" : "Select All", systemImage: "checklist", action: onSelectAll)
                    .labelStyle(.iconOnly).help(allSelected ? "Clear selection" : "Select all visible, confirmable records").disabled(!canSelect)
            }
            Text("\(activeCount) active, \(handledCount) handled").font(.caption).foregroundStyle(.secondary)
            TextField("Search input or meanings", text: $query.text).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Course", selection: $query.courseID) {
                    Text("All courses").tag(UUID?.none)
                    ForEach(courses.sorted { $0.courseName < $1.courseName }, id: \.id) { Text($0.courseName).tag(Optional($0.id)) }
                    if let id = query.courseID, !courses.contains(where: { $0.id == id }) { Text("Unavailable course").tag(Optional(id)) }
                }.labelsHidden().help("Capture course")
                Picker("Source", selection: $query.source) {
                    Text("All sources").tag(SourceType?.none)
                    ForEach(SourceType.allCases) { Text(AppLocalization.text($0.displayTitle)).tag(Optional($0)) }
                }.labelsHidden().help("Capture source")
            }
            Picker("Status", selection: $query.status) {
                ForEach(InboxStatusFilter.allCases) { Text(AppLocalization.text($0.title)).tag($0) }
            }
            HStack {
                Text("\(selectedCounts.records) inputs, \(selectedCounts.candidates) candidates selected")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Confirm Selected", systemImage: "checkmark.circle", action: onConfirm)
                    .labelStyle(.iconOnly).help("Preview and confirm selected candidates").disabled(selectedCounts.candidates == 0)
            }
        }.padding(16)
    }
}
#endif
