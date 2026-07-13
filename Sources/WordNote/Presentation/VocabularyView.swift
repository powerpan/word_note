import SwiftData
import SwiftUI
import WordNoteCore

struct VocabularyView: View {
    @Query private var storedTerms: [TermModel]
    @Query private var storedCourses: [CourseModel]

    @State private var searchText = ""
    @State private var selectedCourseID: UUID?
    @State private var selectedMasteryRaw = "all"
    @State private var selectedTermID: UUID?

    private var terms: [TermModel] {
        storedTerms.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var courses: [CourseModel] {
        storedCourses.sorted { $0.courseName.localizedStandardCompare($1.courseName) == .orderedAscending }
    }

    private var filteredTerms: [TermModel] {
        terms.filter { term in
            let matchesSearch = VocabularySearchMatcher.matches(
                query: searchText,
                term: term.term,
                chineseMeaning: term.chineseMeaning,
                englishDefinition: term.englishDefinition
            )
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
        GeometryReader { proxy in
            let listWidth = VocabularyLayoutMetrics.listWidth(for: proxy.size.width)

            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    filterBar

                    List(selection: $selectedTermID) {
                        ForEach(filteredTerms, id: \.id) { term in
                            VocabularyRow(term: term, courseName: courseName(for: term.courseID))
                                .tag(term.id)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(WordNoteTheme.surface)
                    .overlay {
                        if filteredTerms.isEmpty {
                            EmptyStateView(
                                systemImage: "books.vertical",
                                title: terms.isEmpty ? "No Terms Yet" : "No Matches",
                                message: terms.isEmpty
                                    ? "Analyze a record in Quick Add, then save candidates from Inbox."
                                    : "Try a different search, course, or mastery filter."
                            ) {
                                EmptyView()
                            }
                            .allowsHitTesting(false)
                        }
                    }
                }
                .frame(width: listWidth)
                .background(WordNoteTheme.surface)

                Divider()

                if let selectedTerm {
                    TermDetailEditor(term: selectedTerm, courses: courses)
                        .frame(
                            minWidth: VocabularyLayoutMetrics.minDetailWidth,
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )
                } else {
                    EmptyStateView(
                        systemImage: "book",
                        title: "No Term Selected",
                        message: filteredTerms.isEmpty
                            ? "Your saved terms will appear here after candidate review."
                            : "Select a term to edit definitions, context, course, and review state."
                    ) {
                        EmptyView()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: VocabularyLayoutMetrics.minContentWidth, minHeight: 620)
        .onAppear(perform: maintainSelection)
        .onChange(of: filteredTerms.map(\.id)) { maintainSelection() }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(
                title: "Vocabulary",
                subtitle: "\(filteredTerms.count) / \(terms.count) terms"
            ) {
                EmptyView()
            }

            TextField("Search English or Chinese meanings", text: $searchText)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Picker("Course", selection: $selectedCourseID) {
                    Text("All Courses").tag(UUID?.none)
                    ForEach(courses, id: \.id) { course in
                        Text(course.courseName).tag(Optional(course.id))
                    }
                }
                .frame(maxWidth: 170)

                Picker("Mastery", selection: $selectedMasteryRaw) {
                    Text("All Mastery").tag("all")
                    ForEach(MasteryLevel.allCases) { masteryLevel in
                        Text(masteryLevel.displayTitle).tag(masteryLevel.rawValue)
                    }
                }
                .frame(maxWidth: 170)
            }
        }
        .padding([.horizontal, .top], 18)
    }

    private func courseName(for courseID: UUID?) -> String? {
        guard let courseID else { return nil }
        return courses.first { $0.id == courseID }?.courseName
    }

    private func maintainSelection() {
        if let selectedTermID, filteredTerms.contains(where: { $0.id == selectedTermID }) {
            return
        }
        selectedTermID = filteredTerms.first?.id
    }
}

private enum VocabularyLayoutMetrics {
    static let minContentWidth: CGFloat = 860
    static let minListWidth: CGFloat = 340
    static let maxListWidth: CGFloat = 430
    static let minDetailWidth: CGFloat = 500

    static func listWidth(for contentWidth: CGFloat) -> CGFloat {
        min(max(contentWidth * 0.38, minListWidth), maxListWidth)
    }
}

private struct VocabularyRow: View {
    let term: TermModel
    let courseName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(term.term)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                TagChip(title: term.masteryLevel.displayTitle, tint: WordNoteTheme.teal)
                TagChip(title: term.importance.displayTitle, tint: WordNoteTheme.amber)
                if let courseName {
                    Text(courseName)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
    }
}
