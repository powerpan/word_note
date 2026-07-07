import SwiftData
import SwiftUI
import WordNoteCore

struct VocabularyView: View {
    @Query(sort: \TermModel.updatedAt, order: .reverse) private var terms: [TermModel]
    @Query(sort: \CourseModel.courseName) private var courses: [CourseModel]

    @State private var searchText = ""
    @State private var selectedCourseID: UUID?
    @State private var selectedMasteryRaw = "all"
    @State private var selectedTermID: UUID?

    private var filteredTerms: [TermModel] {
        terms.filter { term in
            let matchesSearch = searchText.isEmpty ||
                term.normalizedTerm.contains(TextNormalizer.normalized(searchText)) ||
                (term.chineseMeaning ?? "").localizedCaseInsensitiveContains(searchText) ||
                (term.englishDefinition ?? "").localizedCaseInsensitiveContains(searchText)
            let matchesCourse = selectedCourseID == nil || term.courseID == selectedCourseID
            let matchesMastery = selectedMasteryRaw == "all" || term.masteryLevel.rawValue == selectedMasteryRaw
            return matchesSearch && matchesCourse && matchesMastery
        }
    }

    private var selectedTerm: TermModel? {
        guard let selectedTermID else { return filteredTerms.first }
        return filteredTerms.first { $0.id == selectedTermID }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 12) {
                filterBar

                List(selection: $selectedTermID) {
                    ForEach(filteredTerms, id: \.id) { term in
                        VocabularyRow(term: term, courseName: courseName(for: term.courseID))
                            .tag(term.id)
                    }
                }
                .overlay {
                    if filteredTerms.isEmpty {
                        ContentUnavailableView(
                            "No Terms",
                            systemImage: "books.vertical",
                            description: Text("Save candidates from Inbox to build your vocabulary.")
                        )
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 380)

            if let selectedTerm {
                TermDetailEditor(term: selectedTerm, courses: courses)
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No Term Selected", systemImage: "book")
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, minHeight: 620)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vocabulary")
                .font(.largeTitle.bold())

            TextField("Search terms", text: $searchText)
                .textFieldStyle(.roundedBorder)

            HStack {
                Picker("Course", selection: $selectedCourseID) {
                    Text("All Courses").tag(UUID?.none)
                    ForEach(courses, id: \.id) { course in
                        Text(course.courseName).tag(Optional(course.id))
                    }
                }

                Picker("Mastery", selection: $selectedMasteryRaw) {
                    Text("All Mastery").tag("all")
                    ForEach(MasteryLevel.allCases) { masteryLevel in
                        Text(masteryLevel.displayTitle).tag(masteryLevel.rawValue)
                    }
                }
            }
        }
        .padding([.horizontal, .top], 18)
    }

    private func courseName(for courseID: UUID?) -> String? {
        guard let courseID else { return nil }
        return courses.first { $0.id == courseID }?.courseName
    }
}

private struct VocabularyRow: View {
    let term: TermModel
    let courseName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(term.term)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(term.masteryLevel.displayTitle)
                Text(term.importance.displayTitle)
                if let courseName {
                    Text(courseName)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct TermDetailEditor: View {
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Term Detail")
                        .font(.largeTitle.bold())
                    Spacer()
                    Button("Save") {
                        save()
                    }
                    Button("Delete", role: .destructive) {
                        delete()
                    }
                }

                if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }

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
            .padding(28)
        }
        .onAppear(perform: loadTerm)
        .onChange(of: term.id) {
            loadTerm()
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
        let service = VocabularyService(modelContext: modelContext)

        do {
            try service.updateTerm(
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
        let service = VocabularyService(modelContext: modelContext)

        do {
            try service.delete(term)
            statusMessage = nil
            errorMessage = nil
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }
}
