import SwiftData
import SwiftUI
import WordNoteCore

#if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
struct VocabularyView: View {
    var body: some View { V2VocabularyView() }
}
#else
struct VocabularyView: View {
    @Environment(\.editProtection) private var editProtection
    private var memberships = AppCourseMemberships()
    @Environment(WordNoteDataProtection.self) private var dataProtection
    @Query private var storedTerms: [TermModel]
    @Query private var storedCourses: [CourseModel]

    @State private var searchText = ""
    @State private var selectedCourseID: UUID?
    @State private var selectedMasteryRaw = "all"
    @State private var selectedTermID: UUID?
    @State private var exportMessage: String?

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
            let matchesCourse = memberships.matches(term, courseID: selectedCourseID)
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

                    List(selection: protected($selectedTermID)) {
                        ForEach(filteredTerms, id: \.id) { term in
                            VocabularyRow(term: term, courseName: memberships.names(for: term, courses: courses))
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
                        .id(selectedTerm.id)
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
        .alert("Vocabulary Export", isPresented: Binding(
            get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(exportMessage ?? "") }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(
                title: "Vocabulary",
                subtitle: "\(filteredTerms.count) / \(terms.count) terms"
            ) {
                Menu {
                    Button("Export Filtered (\(filteredTerms.count))…", systemImage: "square.and.arrow.up") {
                        export(filteredTerms)
                    }
                    .disabled(filteredTerms.isEmpty)
                    Button("Export Selected…", systemImage: "doc") {
                        if let selectedTerm { export([selectedTerm]) }
                    }
                    .disabled(selectedTerm == nil)
                } label: { Image(systemName: "square.and.arrow.up") }
                .help("Export vocabulary as CSV")
                .accessibilityLabel("Export vocabulary as CSV")
                .disabled(dataProtection.isWorking || dataProtection.isRestoring)
            }

            TextField("Search English or Chinese meanings", text: protected($searchText))
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Picker("Course", selection: protected($selectedCourseID)) {
                    Text("All Courses").tag(UUID?.none)
                    ForEach(courses, id: \.id) { course in
                        Text(course.courseName).tag(Optional(course.id))
                    }
                }
                .frame(maxWidth: 170)

                Picker("Mastery", selection: protected($selectedMasteryRaw)) {
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

    private func export(_ selectedTerms: [TermModel]) {
        let courseMemberships = Dictionary(uniqueKeysWithValues: selectedTerms.map { ($0.id, memberships.ids(for: $0)) })
        let terms = selectedTerms.map(WordNoteSnapshotPayload.Term.init)
        let courses = courses.map(WordNoteSnapshotPayload.Course.init)
        Task {
            guard let url = await DataFilePicker.exportURL(csvCount: terms.count) else { return }
            do {
                try await dataProtection.exportVocabulary(terms: terms, courses: courses, courseMemberships: courseMemberships, to: url)
                exportMessage = "Exported \(terms.count) vocabulary entries."
            } catch { exportMessage = error.localizedDescription }
        }
    }

    private func maintainSelection() {
        if let selectedTermID, filteredTerms.contains(where: { $0.id == selectedTermID }) {
            return
        }
        selectedTermID = filteredTerms.first?.id
    }

    private func protected<Value: Equatable>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(get: { binding.wrappedValue }, set: { value in
            guard binding.wrappedValue != value else { return }
            protectingEdits(editProtection) { binding.wrappedValue = value }
        })
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
#endif
