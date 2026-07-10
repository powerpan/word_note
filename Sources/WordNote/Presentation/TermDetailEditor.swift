import SwiftData
import SwiftUI
import WordNoteCore

struct TermDetailEditor: View {
    @Environment(\.modelContext) private var modelContext

    let term: TermModel
    let courses: [CourseModel]

    @State private var termText = ""
    @State private var termType: TermType = .word
    @State private var chineseMeaning = ""
    @State private var englishDefinition = ""
    @State private var aiContextExplanation = ""
    @State private var exampleSentence = ""
    @State private var contextSentence = ""
    @State private var courseID: UUID?
    @State private var sourceType: SourceType = .other
    @State private var category: TermCategory = .general
    @State private var importance: Importance = .medium
    @State private var masteryLevel: MasteryLevel = .new
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var isDeleteConfirmationPresented = false

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

                coreFields
                metadataFields
            }
            .padding(28)
        }
        .onAppear(perform: loadTerm)
        .onChange(of: term.id) { loadTerm() }
    }

    private var coreFields: some View {
        GroupBox("Core") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                formRow("Term") {
                    TextField("Term", text: $termText)
                }
                formRow("Type") {
                    Picker("Type", selection: $termType) {
                        ForEach(TermType.allCases) { type in
                            Text(type.displayTitle).tag(type)
                        }
                    }
                }
                formRow("Chinese") {
                    TextField("Chinese meaning", text: $chineseMeaning, axis: .vertical)
                        .lineLimit(1...4)
                }
                formRow("English") {
                    TextField("English definition", text: $englishDefinition, axis: .vertical)
                        .lineLimit(1...4)
                }
                formRow("AI Context") {
                    TextField("AI / CS context explanation", text: $aiContextExplanation, axis: .vertical)
                        .lineLimit(2...6)
                }
                formRow("Example") {
                    TextField("Example sentence", text: $exampleSentence, axis: .vertical)
                        .lineLimit(1...4)
                }
                formRow("Context") {
                    TextField("Original context", text: $contextSentence, axis: .vertical)
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
                    Picker("Course", selection: $courseID) {
                        Text("No Course").tag(UUID?.none)
                        ForEach(courses, id: \.id) { course in
                            Text(course.courseName).tag(Optional(course.id))
                        }
                    }
                }
                formRow("Source") {
                    Picker("Source", selection: $sourceType) {
                        ForEach(SourceType.allCases) { sourceType in
                            Text(sourceType.displayTitle).tag(sourceType)
                        }
                    }
                }
                formRow("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(TermCategory.allCases) { category in
                            Text(category.displayTitle).tag(category)
                        }
                    }
                }
                formRow("Importance") {
                    Picker("Importance", selection: $importance) {
                        ForEach(Importance.allCases) { importance in
                            Text(importance.displayTitle).tag(importance)
                        }
                    }
                }
                formRow("Mastery") {
                    Picker("Mastery", selection: $masteryLevel) {
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
        termText = term.term
        termType = term.termType
        chineseMeaning = term.chineseMeaning ?? ""
        englishDefinition = term.englishDefinition ?? ""
        aiContextExplanation = term.aiContextExplanation ?? ""
        exampleSentence = term.exampleSentence ?? ""
        contextSentence = term.contextSentence ?? ""
        courseID = term.courseID
        sourceType = term.sourceType
        category = term.category
        importance = term.importance
        masteryLevel = term.masteryLevel
        statusMessage = nil
        errorMessage = nil
    }

    private func save() {
        do {
            try VocabularyService(modelContext: modelContext).updateTerm(
                term,
                termText: termText,
                termType: termType,
                chineseMeaning: chineseMeaning,
                englishDefinition: englishDefinition,
                aiContextExplanation: aiContextExplanation,
                exampleSentence: exampleSentence,
                contextSentence: contextSentence,
                courseID: courseID,
                sourceType: sourceType,
                category: category,
                importance: importance,
                masteryLevel: masteryLevel
            )
            statusMessage = "Saved."
            errorMessage = nil
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        do {
            try VocabularyService(modelContext: modelContext).delete(term)
            statusMessage = nil
            errorMessage = nil
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }
}
