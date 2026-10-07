import SwiftData
import SwiftUI
import WordNoteCore

struct TermDetailEditor: View {
    @Environment(\.modelContext) private var modelContext
    private var memberships = AppCourseMemberships()

    let term: TermModel
    let courses: [CourseModel]

    @State private var values = WordNoteEditDraft(TermEditorValues())
    @State private var draftID = UUID()
    private var draft: TermEditorValues { get { values.value } nonmutating set { values.value = newValue } }
    private var original: TermEditorValues { get { values.baseline } nonmutating set { values.baseline = newValue } }
    private var editRevision: Int { get { values.revision } nonmutating set { values.revision = newValue } }
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var isDeleteConfirmationPresented = false

    private var isDirty: Bool { draft != original }
    private var hasConflict: Bool { editRevision != term.editRevision }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "Term Detail",
                    subtitle: "Edit definitions, context, metadata, and review state."
                ) {
                    Button("Save", action: save)
                    Button("Delete", role: .destructive) {
                        isDeleteConfirmationPresented = true
                    }
                    .confirmationDialog(
                        "Delete this vocabulary term?",
                        isPresented: $isDeleteConfirmationPresented
                    ) {
                        Button("Delete Term", role: .destructive, action: delete)
                    } message: {
                        Text("Review history for this term will also be deleted. This cannot be undone.")
                    }
                }

                if let statusMessage {
                    StatusBanner(message: statusMessage, kind: .success)
                }
                if let errorMessage {
                    StatusBanner(message: errorMessage, kind: .warning)
                }
                if hasConflict && isDirty {
                    StatusBanner(message: "This term changed in another operation. Your draft has not been overwritten.", kind: .warning)
                }
                if isDirty {
                    Button("Discard Changes", action: loadTerm)
                }

                coreFields
                metadataFields
            }
            .padding(28)
        }
        .groupBoxStyle(WordNoteGroupBoxStyle())
        .onAppear(perform: loadTerm)
        .onChange(of: term.id) { loadTerm() }
        .onChange(of: term.editRevision) { if !isDirty { loadTerm() } }
        .protectEdits(id: draftID, value: draft, isDirty: { values.isDirty }, title: "Term: \(original.termText)", preview: { values.value.preview },
                      save: capturedSave, discard: discardDraft)
    }

    private var coreFields: some View {
        GroupBox("Core") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                formRow("Term") {
                    TextField("Term", text: $values.value.termText)
                }
                formRow("Type") {
                    Picker("Type", selection: $values.value.termType) {
                        ForEach(TermType.allCases) { type in
                            Text(type.displayTitle).tag(type)
                        }
                    }
                }
                formRow("Chinese") {
                    TextField("Chinese meaning", text: $values.value.chineseMeaning, axis: .vertical)
                        .lineLimit(1...4)
                }
                formRow("English") {
                    TextField("English definition", text: $values.value.englishDefinition, axis: .vertical)
                        .lineLimit(1...4)
                }
                formRow("AI Context") {
                    TextField("AI / CS context explanation", text: $values.value.aiContextExplanation, axis: .vertical)
                        .lineLimit(2...6)
                }
                formRow("Example") {
                    TextField("Example sentence", text: $values.value.exampleSentence, axis: .vertical)
                        .lineLimit(1...4)
                }
                formRow("Context") {
                    TextField("Original context", text: $values.value.contextSentence, axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var metadataFields: some View {
        GroupBox("Metadata") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                formRow("Course") {
                    #if WORDNOTE_V2_VALIDATION
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(courses, id: \.id) { course in
                            Toggle(course.courseName, isOn: Binding(
                                get: { draft.courseIDs.contains(course.id) },
                                set: { if $0 { draft.courseIDs.insert(course.id) } else { draft.courseIDs.remove(course.id) } }
                            )).toggleStyle(.checkbox)
                        }
                        if courses.isEmpty { Text("No Courses").foregroundStyle(.secondary) }
                    }
                    #else
                    Picker("Course", selection: $values.value.courseID) {
                        Text("No Course").tag(UUID?.none)
                        ForEach(courses, id: \.id) { course in
                            Text(course.courseName).tag(Optional(course.id))
                        }
                    }
                    #endif
                }
                formRow("Source") {
                    Picker("Source", selection: $values.value.sourceType) {
                        ForEach(SourceType.allCases) { sourceType in
                            Text(sourceType.displayTitle).tag(sourceType)
                        }
                    }
                }
                formRow("Category") {
                    Picker("Category", selection: $values.value.category) {
                        ForEach(TermCategory.allCases) { category in
                            Text(category.displayTitle).tag(category)
                        }
                    }
                }
                formRow("Importance") {
                    Picker("Importance", selection: $values.value.importance) {
                        ForEach(Importance.allCases) { importance in
                            Text(importance.displayTitle).tag(importance)
                        }
                    }
                }
                formRow("Mastery") {
                    Picker("Mastery", selection: $values.value.masteryLevel) {
                        ForEach(MasteryLevel.allCases) { masteryLevel in
                            Text(masteryLevel.displayTitle).tag(masteryLevel)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func loadTerm() {
        editRevision = term.editRevision
        draft = TermEditorValues(
            termText: term.term, termType: term.termType, chineseMeaning: term.chineseMeaning ?? "",
            englishDefinition: term.englishDefinition ?? "", aiContextExplanation: term.aiContextExplanation ?? "",
            exampleSentence: term.exampleSentence ?? "", contextSentence: term.contextSentence ?? "",
            courseID: term.courseID, courseIDs: memberships.ids(for: term), sourceType: term.sourceType,
            category: term.category, importance: term.importance, masteryLevel: term.masteryLevel
        )
        original = draft
        statusMessage = nil
        errorMessage = nil
    }

    private func save() {
        do {
            try capturedSave()
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private var capturedSave: () throws -> Void {
        let id = term.id
        return {
            let value = values.value
            let revision = values.revision
            guard let current = try modelContext.fetch(FetchDescriptor<TermModel>()).first(where: { $0.id == id }) else {
                throw WordNoteV2ContentError.missingEntity
            }
            try VocabularyService(modelContext: modelContext, expectedRevision: revision, courseIDs: value.courseIDs).updateTerm(
                current,
                termText: value.termText,
                termType: value.termType,
                chineseMeaning: value.chineseMeaning,
                englishDefinition: value.englishDefinition,
                aiContextExplanation: value.aiContextExplanation,
                exampleSentence: value.exampleSentence,
                contextSentence: value.contextSentence,
                courseID: value.courseID,
                sourceType: value.sourceType,
                category: value.category,
                importance: value.importance,
                masteryLevel: value.masteryLevel
            )
            editRevision = current.editRevision
            draft = value
            original = value
            errorMessage = nil
            statusMessage = "Saved."
        }
    }

    private func discardDraft() {
        draft = original
        errorMessage = nil
    }

    private func delete() {
        do {
            try VocabularyService(modelContext: modelContext, expectedRevision: editRevision, courseIDs: draft.courseIDs).delete(term)
            discardDraft()
            statusMessage = nil
            errorMessage = nil
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct TermEditorValues: Equatable {
    var termText = ""
    var termType: TermType = .word
    var chineseMeaning = ""
    var englishDefinition = ""
    var aiContextExplanation = ""
    var exampleSentence = ""
    var contextSentence = ""
    var courseID: UUID?
    var courseIDs = Set<UUID>()
    var sourceType: SourceType = .other
    var category: TermCategory = .general
    var importance: Importance = .medium
    var masteryLevel: MasteryLevel = .new
    var preview: String {
        [termText, chineseMeaning, englishDefinition, aiContextExplanation, exampleSentence, contextSentence]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
