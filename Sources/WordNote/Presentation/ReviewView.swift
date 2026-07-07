import SwiftData
import SwiftUI
import WordNoteCore

struct ReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TermModel.nextReviewAt) private var terms: [TermModel]
    @Query(sort: \CourseModel.courseName) private var courses: [CourseModel]

    @State private var selectedCourseID: UUID?
    @State private var selectedTermID: UUID?
    @State private var isAnswerVisible = false
    @State private var reviewedCount = 0
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var dueTerms: [TermModel] {
        let endOfToday = Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 60 * 60)
        return terms
            .filter { term in
                guard let nextReviewAt = term.nextReviewAt else { return false }
                let courseMatches = selectedCourseID == nil || term.courseID == selectedCourseID
                return courseMatches && nextReviewAt < endOfToday
            }
            .sorted { lhs, rhs in
                if lhs.nextReviewAt != rhs.nextReviewAt {
                    return (lhs.nextReviewAt ?? .distantFuture) < (rhs.nextReviewAt ?? .distantFuture)
                }
                if lhs.wrongCount != rhs.wrongCount {
                    return lhs.wrongCount > rhs.wrongCount
                }
                if lhs.importance != rhs.importance {
                    return lhs.importance > rhs.importance
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    private var activeTerm: TermModel? {
        if let selectedTermID, let selected = dueTerms.first(where: { $0.id == selectedTermID }) {
            return selected
        }
        return dueTerms.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                title: "Review",
                subtitle: "Review due terms and update the next review date with simple feedback."
            ) {
                EmptyView()
            }

            HStack {
                Picker("Course", selection: $selectedCourseID) {
                    Text("All Courses").tag(UUID?.none)
                    ForEach(courses, id: \.id) { course in
                        Text(course.courseName).tag(Optional(course.id))
                    }
                }
                .frame(maxWidth: 280)

                Spacer()

                Text("\(dueTerms.count) due")
                    .foregroundStyle(.secondary)
            }

            if let statusMessage {
                StatusBanner(message: statusMessage, kind: .success)
            }

            if let errorMessage {
                StatusBanner(message: errorMessage, kind: .warning)
            }

            if let activeTerm {
                ReviewCard(
                    term: activeTerm,
                    courseName: courseName(for: activeTerm.courseID),
                    isAnswerVisible: isAnswerVisible,
                    onShowAnswer: {
                        isAnswerVisible = true
                    },
                    onFeedback: recordFeedback
                )
            } else {
                EmptyStateView(
                    systemImage: "checkmark.circle",
                    title: "No Terms Due",
                    message: reviewedCount == 0 ? "There are no terms scheduled for review today." : "Review complete for this queue."
                ) {
                    EmptyView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer()
        }
        .padding(28)
        .onChange(of: selectedCourseID) {
            selectedTermID = nil
            isAnswerVisible = false
        }
    }

    private func courseName(for courseID: UUID?) -> String? {
        guard let courseID else { return nil }
        return courses.first { $0.id == courseID }?.courseName
    }

    private func recordFeedback(_ feedback: ReviewFeedback) {
        guard let activeTerm else { return }
        let service = ReviewService(modelContext: modelContext)

        do {
            _ = try service.recordFeedback(for: activeTerm, feedback: feedback)
            reviewedCount += 1
            selectedTermID = dueTerms.first { $0.id != activeTerm.id }?.id
            isAnswerVisible = false
            statusMessage = "Recorded: \(feedback.displayTitle)"
            errorMessage = nil
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct ReviewCard: View {
    let term: TermModel
    let courseName: String?
    let isAnswerVisible: Bool
    let onShowAnswer: () -> Void
    let onFeedback: (ReviewFeedback) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(term.term)
                        .font(.system(size: 34, weight: .bold))
                    Spacer()
                    Text(term.importance.displayTitle)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    TagChip(title: term.termType.displayTitle, tint: .blue)
                    TagChip(title: term.masteryLevel.displayTitle, tint: .purple)
                    if let courseName {
                        Text(courseName)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if let contextSentence = term.contextSentence, !contextSentence.isEmpty {
                GroupBox("Context") {
                    Text(contextSentence)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }

            if isAnswerVisible {
                VStack(alignment: .leading, spacing: 12) {
                    answerSection("Chinese", term.chineseMeaning)
                    answerSection("English", term.englishDefinition)
                    answerSection("AI / CS Context", term.aiContextExplanation)
                    answerSection("Example", term.exampleSentence)
                }

                HStack(spacing: 10) {
                    ForEach(ReviewFeedback.allCases) { feedback in
                        Button(feedback.displayTitle) {
                            onFeedback(feedback)
                        }
                    }
                    Spacer()
                }
            } else {
                Button {
                    onShowAnswer()
                } label: {
                    Label("Show Answer", systemImage: "eye")
                }
                .keyboardShortcut(.space, modifiers: [])
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func answerSection(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .textSelection(.enabled)
            }
        }
    }
}
