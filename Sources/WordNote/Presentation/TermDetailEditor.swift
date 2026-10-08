import SwiftData
import SwiftUI
import WordNoteCore

private typealias TermEditorValues = WordNoteTermEditValues

struct TermDetailEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.savedChangeHistory) private var undoHistory
    private var memberships = AppCourseMemberships()

    let term: TermModel
    let courses: [CourseModel]
    var onSaved: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

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
                    title: onClose == nil ? "Term Detail" : "Edit Term",
                    subtitle: onClose == nil ? "Edit definitions, context, metadata, and review state." : term.term
                ) {
                    if let onClose {
                        Button("Return to Reading", systemImage: "arrow.left", action: onClose)
                            .labelStyle(.iconOnly).help("Return to reading")
                    }
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
                    #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
                    DraftConflictView(draft: values, fields: TermEditorValues.comparisonFields(courseNames: courseNames),
                                      loadCurrent: { try storedVersion(id: term.id) }, onApplied: { errorMessage = nil; statusMessage = nil })
                    #else
                    StatusBanner(message: "This term changed in another operation. Your draft has not been overwritten.", kind: .warning)
                    #endif
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
        .protectEdits(id: draftID, value: draft, isDirty: { values.isDirty }, title: AppLocalization.format("Term: %@", original.termText), preview: { values.value.preview },
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
                            Text(AppLocalization.text(type.displayTitle)).tag(type)
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
                    #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
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
                            Text(AppLocalization.text(sourceType.displayTitle)).tag(sourceType)
                        }
                    }
                }
                formRow("Category") {
                    Picker("Category", selection: $values.value.category) {
                        ForEach(TermCategory.allCases) { category in
                            Text(AppLocalization.text(category.displayTitle)).tag(category)
                        }
                    }
                }
                formRow("Importance") {
                    Picker("Importance", selection: $values.value.importance) {
                        ForEach(Importance.allCases) { importance in
                            Text(AppLocalization.text(importance.displayTitle)).tag(importance)
                        }
                    }
                }
                #if !WORDNOTE_V3_VALIDATION
                formRow("Mastery") {
                    Picker("Mastery", selection: $values.value.masteryLevel) {
                        ForEach(MasteryLevel.allCases) { masteryLevel in
                            Text(AppLocalization.text(masteryLevel.displayTitle)).tag(masteryLevel)
                        }
                    }
                }
                #endif
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(AppLocalization.text(title))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func loadTerm() {
        do {
            let version = try storedVersion(id: term.id)
            editRevision = version.revision
            draft = version.value
            original = draft
            statusMessage = nil
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private var courseNames: [UUID: String] {
        Dictionary(uniqueKeysWithValues: courses.map { ($0.id, "\($0.courseName) [\($0.id.uuidString.prefix(8))]") })
    }

    private func storedVersion(id: UUID) throws -> WordNoteDraftVersion<TermEditorValues> {
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        return try AppContentService(container: modelContext.container).termDraftVersion(id)
        #else
        guard let current = try modelContext.fetch(FetchDescriptor<TermModel>()).first(where: { $0.id == id }) else {
            throw AppContentError.missingEntity
        }
        let value = TermEditorValues(
            termText: current.term, termType: current.termType, chineseMeaning: current.chineseMeaning ?? "",
            englishDefinition: current.englishDefinition ?? "", aiContextExplanation: current.aiContextExplanation ?? "",
            exampleSentence: current.exampleSentence ?? "", contextSentence: current.contextSentence ?? "",
            courseID: current.courseID, courseIDs: memberships.ids(for: current), sourceType: current.sourceType,
            category: current.category, importance: current.importance, masteryLevel: current.masteryLevel
        )
        return WordNoteDraftVersion(value, revision: current.editRevision)
        #endif
    }

    private func save() {
        do {
            try capturedSave()
            onSaved?()
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
                throw AppContentError.missingEntity
            }
            try VocabularyService(modelContext: modelContext, expectedRevision: revision, courseIDs: value.courseIDs, undoHistory: undoHistory).updateTerm(
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
            let saved = try storedVersion(id: id)
            editRevision = saved.revision
            draft = saved.value
            original = saved.value
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
