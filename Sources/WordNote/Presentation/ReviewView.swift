#if !WORDNOTE_V3_VALIDATION
import SwiftData
import SwiftUI
import WordNoteCore

struct ReviewView: View {
    private var memberships = AppCourseMemberships()
    @Environment(\.modelContext) private var modelContext
    @Query private var terms: [TermModel]
    @Query private var storedCourses: [CourseModel]

    @State private var selectedCourseID: UUID?
    @State private var reviewMode: ReviewMode = .englishToChinese
    @State private var queueScope: ReviewQueueScope = .dueToday
    @State private var queueIDs: [UUID] = []
    @State private var handledTermIDs = Set<UUID>()
    @State private var isAnswerVisible = false
    @State private var feedbackCounts: [ReviewFeedback: Int] = [:]
    @State private var postponedCount = 0
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var courses: [CourseModel] {
        storedCourses.sorted { $0.courseName.localizedStandardCompare($1.courseName) == .orderedAscending }
    }

    private var availableTerms: [TermModel] {
        ReviewQueuePolicy().terms(
            from: terms.filter { memberships.matches($0, courseID: selectedCourseID) },
            scope: queueScope
        )
    }

    private var activeTerm: TermModel? {
        guard let activeID = queueIDs.first else { return nil }
        return availableTerms.first { $0.id == activeID }
    }

    private var reviewedCount: Int {
        feedbackCounts.values.reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(
                title: "Review",
                subtitle: queueScope == .dueToday
                    ? "Work through terms scheduled for today."
                    : "Practice terms raised by mistakes and repeated lookups."
            ) {
                Text("\(queueIDs.count) remaining")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            reviewControls

            if let statusMessage {
                StatusBanner(message: statusMessage, kind: .success)
            }
            if let errorMessage {
                StatusBanner(message: errorMessage, kind: .warning)
            }

            if let activeTerm {
                ReviewCard(
                    term: activeTerm,
                    courseName: memberships.names(for: activeTerm, courses: courses),
                    mode: reviewMode,
                    isAnswerVisible: isAnswerVisible,
                    onShowAnswer: { isAnswerVisible = true },
                    onFeedback: recordFeedback,
                    onSkip: skipActiveTerm,
                    onLater: postponeActiveTerm
                )
            } else if reviewedCount > 0 || postponedCount > 0 {
                ReviewCompletionView(
                    feedbackCounts: feedbackCounts,
                    postponedCount: postponedCount,
                    onRestart: startSession
                )
            } else {
                EmptyStateView(
                    systemImage: queueScope == .dueToday ? "checkmark.circle" : "brain.head.profile",
                    title: queueScope == .dueToday ? "No Terms Due" : "No Weak Terms",
                    message: queueScope == .dueToday
                        ? "There are no terms scheduled for review today."
                        : "Repeated lookups and difficult reviews will appear here."
                ) {
                    EmptyView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .onAppear(perform: startSession)
        .onChange(of: selectedCourseID) { startSession() }
        .onChange(of: queueScope) { startSession() }
        .onChange(of: reviewMode) { isAnswerVisible = false }
        .onChange(of: availableTerms.map(\.id)) { syncQueueWithAvailableTerms() }
    }

    private var reviewControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                scopePicker
                modePicker
                coursePicker
            }
            VStack(alignment: .leading, spacing: 10) {
                scopePicker
                modePicker
                coursePicker
            }
        }
    }

    private var scopePicker: some View {
        Picker("Queue", selection: $queueScope) {
            ForEach(ReviewQueueScope.allCases) { scope in
                Text(AppLocalization.text(scope.displayTitle)).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)
    }

    private var modePicker: some View {
        Picker("Mode", selection: $reviewMode) {
            Text("English → Chinese").tag(ReviewMode.englishToChinese)
            Text("Chinese → English").tag(ReviewMode.chineseToEnglish)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 300)
    }

    private var coursePicker: some View {
        Picker("Course", selection: $selectedCourseID) {
            Text("All Courses").tag(UUID?.none)
            ForEach(courses, id: \.id) { course in
                Text(course.courseName).tag(Optional(course.id))
            }
        }
        .frame(maxWidth: 260)
    }

    private func courseName(for courseID: UUID?) -> String? {
        guard let courseID else { return nil }
        return courses.first { $0.id == courseID }?.courseName
    }

    private func startSession() {
        handledTermIDs.removeAll()
        queueIDs = availableTerms.map(\.id)
        feedbackCounts.removeAll()
        postponedCount = 0
        isAnswerVisible = false
        statusMessage = nil
        errorMessage = nil
    }

    private func syncQueueWithAvailableTerms() {
        let availableIDs = availableTerms.map(\.id).filter { !handledTermIDs.contains($0) }
        let availableIDSet = Set(availableIDs)
        queueIDs.removeAll { !availableIDSet.contains($0) }
        for id in availableIDs where !queueIDs.contains(id) {
            queueIDs.append(id)
        }
        if activeTerm == nil {
            isAnswerVisible = false
        }
    }

    private func recordFeedback(_ feedback: ReviewFeedback) {
        guard let activeTerm else { return }
        let service = ReviewService(modelContext: modelContext)

        do {
            _ = try service.recordFeedback(for: activeTerm, mode: reviewMode, feedback: feedback)
            handledTermIDs.insert(activeTerm.id)
            queueIDs.removeAll { $0 == activeTerm.id }
            feedbackCounts[feedback, default: 0] += 1
            isAnswerVisible = false
            statusMessage = "Recorded: \(AppLocalization.text(feedback.displayTitle))"
            errorMessage = nil
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func skipActiveTerm() {
        guard queueIDs.count > 1 else {
            statusMessage = "This is the last term in the current queue."
            return
        }
        let skippedID = queueIDs.removeFirst()
        queueIDs.append(skippedID)
        isAnswerVisible = false
        statusMessage = "Moved to the end of this session."
        errorMessage = nil
    }

    private func postponeActiveTerm() {
        guard let activeTerm else { return }
        let service = ReviewService(modelContext: modelContext)

        do {
            try service.postponeUntilTomorrow(activeTerm)
            handledTermIDs.insert(activeTerm.id)
            queueIDs.removeAll { $0 == activeTerm.id }
            postponedCount += 1
            isAnswerVisible = false
            statusMessage = "Moved to tomorrow without changing review statistics."
            errorMessage = nil
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct ReviewCard: View {
    @AppStorage(CommandShortcutPreference.storageKey) private var commandShortcutsEnabled = CommandShortcutPreference.defaultValue
    let term: TermModel
    let courseName: String?
    let mode: ReviewMode
    let isAnswerVisible: Bool
    let onShowAnswer: () -> Void
    let onFeedback: (ReviewFeedback) -> Void
    let onSkip: () -> Void
    let onLater: () -> Void

    private var promptText: String {
        switch mode {
        case .chineseToEnglish:
            return term.chineseMeaning ?? term.englishDefinition ?? "No definition available"
        case .englishToChinese, .contextCloze:
            return term.term
        }
    }

    private var contextText: String? {
        guard let context = term.contextSentence, !context.isEmpty else { return nil }
        if mode == .chineseToEnglish {
            return context.replacingOccurrences(
                of: term.term,
                with: "_____",
                options: [.caseInsensitive]
            )
        }
        return context
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(promptText)
                        .font(.system(size: mode == .chineseToEnglish ? 26 : 34, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        TagChip(title: AppLocalization.text(term.termType.displayTitle), tint: WordNoteTheme.teal)
                        TagChip(title: AppLocalization.text(term.masteryLevel.displayTitle), tint: WordNoteTheme.brand)
                        if let courseName {
                            Text(courseName)
                                .lineLimit(1)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button(action: onSkip) {
                        Label("Skip", systemImage: "forward")
                    }
                    .help("Move this term to the end of the current session")

                    Button(action: onLater) {
                        Label("Later", systemImage: "calendar.badge.clock")
                    }
                    .help("Move this term to tomorrow without recording an answer")
                }
            }

            if let contextText {
                GroupBox("Context") {
                    Text(contextText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }

            if isAnswerVisible {
                if mode == .chineseToEnglish {
                    Text(term.term)
                        .font(.title.bold())
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 12) {
                    answerSection("Chinese", term.chineseMeaning)
                    answerSection("English", term.englishDefinition)
                    answerSection("AI / CS Context", term.aiContextExplanation)
                    answerSection("Example", term.exampleSentence)
                }

                HStack(spacing: 10) {
                    feedbackButton(.again, key: "1", keyLabel: "1")
                    feedbackButton(.hard, key: "2", keyLabel: "2")
                    feedbackButton(.good, key: "3", keyLabel: "3")
                    feedbackButton(.easy, key: "4", keyLabel: "4")
                    Spacer()
                }
            } else {
                Button(action: onShowAnswer) {
                    Label("Show Answer", systemImage: "eye")
                }
                .commandShortcut(.space, modifiers: [])
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wordNoteSurface(elevated: true)
        .groupBoxStyle(WordNoteGroupBoxStyle())
    }

    private func feedbackButton(
        _ feedback: ReviewFeedback,
        key: KeyEquivalent,
        keyLabel: String
    ) -> some View {
        Button {
            onFeedback(feedback)
        } label: {
            Text(commandShortcutsEnabled ? "\(keyLabel)  \(AppLocalization.text(feedback.displayTitle))" : AppLocalization.text(feedback.displayTitle))
        }
        .commandShortcut(key, modifiers: [])
        .help(commandShortcutsEnabled ? "Record \(AppLocalization.text(feedback.displayTitle)) (\(keyLabel))" : AppLocalization.text(feedback.displayTitle))
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

private struct ReviewCompletionView: View {
    let feedbackCounts: [ReviewFeedback: Int]
    let postponedCount: Int
    let onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Session Complete", systemImage: "checkmark.circle.fill")
                .font(.title2.bold())
                .foregroundStyle(WordNoteTheme.green)

            HStack(spacing: 24) {
                ForEach(ReviewFeedback.allCases) { feedback in
                    LabeledContent(AppLocalization.text(feedback.displayTitle)) {
                        Text(feedbackCounts[feedback, default: 0], format: .number)
                            .monospacedDigit()
                    }
                }
                LabeledContent("Later") {
                    Text(postponedCount, format: .number)
                        .monospacedDigit()
                }
            }

            Button(action: onRestart) {
                Label("Refresh Queue", systemImage: "arrow.clockwise")
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wordNoteSurface(elevated: true)
    }
}
#endif
