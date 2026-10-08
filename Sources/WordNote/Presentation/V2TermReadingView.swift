#if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
import SwiftData
import SwiftUI
import WordNoteCore

struct V2TermDetailSurface: View {
    @Environment(\.editProtection) private var editProtection
    let term: TermModel
    let courses: [CourseModel]
    let onOrganize: () -> Void
    @State private var isEditing = false

    var body: some View {
        if isEditing {
            TermDetailEditor(term: term, courses: courses, onSaved: { isEditing = false }, onClose: {
                protectingEdits(editProtection) { isEditing = false }
            })
        } else {
            V2TermReadingView(term: term, courses: courses, onEdit: { isEditing = true }, onOrganize: onOrganize)
        }
    }
}

private struct V2TermReadingView: View {
    private var memberships = AppCourseMemberships()
    let term: TermModel
    let courses: [CourseModel]
    let onEdit: () -> Void
    let onOrganize: () -> Void
    @Query private var occurrences: [AppSchema.TermOccurrenceModel]

    init(term: TermModel, courses: [CourseModel], onEdit: @escaping () -> Void, onOrganize: @escaping () -> Void) {
        self.term = term
        self.courses = courses
        self.onEdit = onEdit
        self.onOrganize = onOrganize
        let id = term.id
        _occurrences = Query(filter: #Predicate<AppSchema.TermOccurrenceModel> { $0.termID == id })
    }

    var body: some View {
        let content = VocabularyReadingContent(term: .init(term), occurrences: occurrences.map(WordNoteSnapshotV2Payload.Occurrence.init))
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(term.term).font(WordNoteTheme.editorialFont(size: 28, weight: .semibold))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text("\(term.termType.displayTitle), \(term.category.displayTitle)").font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("Organize", systemImage: "tag", action: onOrganize)
                        .labelStyle(.iconOnly).help("Organize courses and tags")
                    Button("Edit", systemImage: "pencil", action: onEdit)
                        .labelStyle(.iconOnly).help("Edit term")
                }
                if content.meanings.isEmpty { Text("No definition available.").foregroundStyle(.secondary) }
                ForEach(content.meanings) { section in readingSection(section) }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Organization").font(.headline)
                    LabeledContent("Courses", value: memberships.names(for: term, courses: courses) ?? "No course")
                    LabeledContent("Tags", value: term.tags.isEmpty ? "No tags" : term.tags.joined(separator: ", "))
                }.textSelection(.enabled)
                if !content.sources.isEmpty {
                    Divider()
                    ForEach(content.sources) { section in readingSection(section) }
                    if let source = content.source {
                        Text(source.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                #if WORDNOTE_V3_VALIDATION
                V3TermReviewCardsView(term: term)
                #else
                VStack(alignment: .leading, spacing: 10) {
                    Text("Learning").font(.headline)
                    LabeledContent("Mastery", value: term.masteryLevel.displayTitle)
                    LabeledContent("Importance", value: term.importance.displayTitle)
                    LabeledContent("Next review", value: term.nextReviewAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not scheduled")
                    LabeledContent("Last review", value: term.lastReviewedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not reviewed")
                    LabeledContent("Legacy reviews", value: String(term.reviewCount))
                    LabeledContent("Legacy wrong / re-query count", value: String(term.wrongCount))
                        .help("This historical counter includes review ratings and repeated lookups.")
                }.font(.subheadline)
                #endif
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.background(WordNoteTheme.canvas)
    }

    private func readingSection(_ section: VocabularyReadingContent.Section) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text(section.text).font(.system(size: 15)).lineSpacing(5)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
