#if WORDNOTE_V3_VALIDATION
import SwiftData
import SwiftUI
import WordNoteCore

struct ReviewView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.learningWorkspace) private var workspace
    @Environment(WordNoteDataProtection.self) private var protection
    @Query private var courses: [CourseModel]
    @State private var controller: V3ReviewController?
    @State private var startupError: String?
    @State private var localSetup = ReviewSetupSelection()
    private var setupSelection: Binding<ReviewSetupSelection> {
        Binding(get: { workspace?.review ?? localSetup }, set: { value in
            if let workspace { workspace.review = value } else { localSetup = value }
        })
    }
    @State private var confirmEnd = false
    @AppStorage(WordNoteLearningPreferences.targetStorageKey) private var target = 20
    @AppStorage(WordNoteLearningPreferences.newLimitStorageKey) private var newLimit = 10

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Review").font(WordNoteTheme.editorialFont(size: 30, weight: .semibold))
                    Spacer()
                    if let controller, controller.session?.session.status.isResumable == true {
                        if controller.ownsSession {
                            Button("Pause", systemImage: "pause", action: { controller.pause() })
                        }
                        Button("End Group", systemImage: "stop") { confirmEnd = true }
                    }
                }
                if let error = controller?.errorMessage ?? startupError { StatusBanner(message: error, kind: .warning) }
                if let controller {
                    if let session = controller.session {
                        sessionHeader(session, statistics: controller.statistics)
                        if let front = controller.front {
                            V3ReviewQuestionView(controller: controller, front: front)
                        } else if session.session.status.isResumable {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(session.session.status == .waiting ? "Relearning is waiting" : "Continue this group")
                                    .font(.title3.weight(.semibold))
                                if let date = session.items.filter({ $0.status == .waiting }).compactMap(\.availableAt).min() {
                                    LabeledContent("Next relearning", value: date.formatted(date: .abbreviated, time: .shortened))
                                }
                                if !controller.ownsSession {
                                    Button("Continue", systemImage: "play.fill") { controller.resume() }
                                        .buttonStyle(.borderedProminent).disabled(!controller.isWindowActive)
                                }
                            }.padding(.vertical, 20)
                        } else {
                            Text(session.session.status == .completed ? "Group complete" : "Group ended").font(.title2)
                            Button("New Group", systemImage: "plus") { controller.showSetup() }
                        }
                    } else { setup(controller) }
                } else if startupError == nil { ProgressView() }
            }.padding(28).frame(maxWidth: 920, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WordNoteTheme.canvas)
        .background { if let controller { V3ReviewWindowBridge(controller: controller).frame(width: 0, height: 0) } }
        .onAppear {
            do {
                if controller == nil { controller = try V3ReviewController(container: context.container) }
                controller?.setAvailable(!protection.isRestoring)
                controller?.load()
            } catch { startupError = error.localizedDescription }
        }
        .onDisappear { controller?.release() }
        .onChange(of: protection.isRestoring) { controller?.setAvailable(!protection.isRestoring) }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { controller?.tick(at: $0) }
        .disabled(protection.isRestoring)
        .confirmationDialog("End this review group?", isPresented: $confirmEnd) {
            Button("End Group") { controller?.end() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Saved answers remain. Unanswered cards are not counted as completed.") }
    }

    private func setup(_ controller: V3ReviewController) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Course", selection: setupSelection.courseID) {
                Text("All courses").tag(UUID?.none)
                ForEach(courses, id: \.id) { Text($0.courseName).tag(Optional($0.id)) }
                if let id = setupSelection.wrappedValue.courseID, !courses.contains(where: { $0.id == id }) {
                    Text("Unavailable course").tag(Optional(id))
                }
            }
            Picker("Direction", selection: setupSelection.mode) {
                ForEach(ReviewMode.allCases) { Text(AppLocalization.text($0.displayTitle)).tag($0) }
            }
            Picker("Queue", selection: setupSelection.queue) {
                ForEach(ReviewQueueScope.allCases) { Text(AppLocalization.text($0.displayTitle)).tag($0) }
            }
            Toggle("Include new cards", isOn: setupSelection.includesNew).toggleStyle(.checkbox)
            LabeledContent("Group size", value: AppLocalization.format("%lld cards", min(max(target, 5), 100)))
            LabeledContent("Daily new-card limit", value: String(min(max(newLimit, 0), 50)))
            LabeledContent("Study time zone", value: TimeZone.current.identifier)
            Button("Start Review", systemImage: "play.fill") {
                let value = setupSelection.wrappedValue
                controller.start(scope: .init(courseID: value.courseID, mode: value.mode, queue: value.queue,
                    includesNewCards: value.includesNew, studyTimeZoneID: TimeZone.current.identifier),
                    target: min(max(target, 5), 100), newLimit: min(max(newLimit, 0), 50))
            }.buttonStyle(.borderedProminent).disabled(!controller.isWindowActive)
        }.frame(maxWidth: 520, alignment: .leading)
    }

    private func sessionHeader(_ value: WordNoteV3ReviewSessionSnapshot, statistics: ReviewSessionStatistics?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(value.session.scope.courseName ?? AppLocalization.text("All courses")) / \(AppLocalization.text(value.session.scope.mode.displayTitle))")
                .font(.headline)
            Text("\(AppLocalization.text(value.session.scope.queue.displayTitle)) / \(value.session.scope.studyTimeZoneID)")
                .font(.caption).foregroundStyle(.secondary)
            if let statistics {
                ProgressView(value: Double(statistics.processedItems), total: Double(max(1, statistics.totalItems)))
                Text("\(statistics.processedItems) / \(statistics.totalItems) processed").font(.subheadline)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { counts(statistics) }
                    VStack(alignment: .leading, spacing: 8) { counts(statistics) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Divider()
        }
    }

    @ViewBuilder private func counts(_ value: ReviewSessionStatistics) -> some View {
        Text("\(value.reviewed) reviewed")
        Text("\(value.answers.answerCount) answers")
        Text("\(value.waiting) waiting")
        Text("\(value.manualLater + value.relearningLimit + value.siblingDeferred + value.unclassifiedPostponed) deferred")
        Text("\(value.unavailable) unavailable")
    }
}

private struct V3ReviewQuestionView: View {
    @Bindable var controller: V3ReviewController
    let front: ReviewQuestionFront
    @FocusState private var answerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(front.prompt).font(.system(size: 28, weight: .medium))
                .lineSpacing(6).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let back = controller.back {
                answer(back)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { feedbackButtons }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) { feedbackButtons }
                }
            } else {
                if front.allowsTypedAnswer {
                    TextField("Your answer", text: $controller.typedAnswer, axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder).focused($answerFocused)
                }
                Button("Reveal Answer", systemImage: "eye") { answerFocused = false; controller.reveal() }
                    .buttonStyle(.borderedProminent).disabled(!controller.canReveal)
            }
            HStack(spacing: 16) {
                Button("Skip", systemImage: "forward.end") { answerFocused = false; controller.skip() }
                Button("Later", systemImage: "clock") { answerFocused = false; controller.later() }
            }.padding(.top, 8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var feedbackButtons: some View {
        ForEach(ReviewFeedback.allCases) { feedback in
            Button { controller.answer(feedback) } label: {
                VStack(spacing: 5) {
                    Text(AppLocalization.text(feedback.displayTitle)).fontWeight(.semibold)
                    Text(controller.delay(for: feedback)).font(.caption)
                }.frame(minWidth: 110, maxWidth: .infinity, minHeight: 44)
            }.disabled(!controller.canAnswer)
        }
    }

    private func answer(_ value: ReviewQuestionBack) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text(value.answer).font(.title3.weight(.semibold)).lineSpacing(5)
            if front.mode == .contextCloze, value.englishTerm != value.answer {
                LabeledContent("Vocabulary", value: value.englishTerm)
            }
            if !value.acceptedAnswers.isEmpty {
                LabeledContent("Also accepted", value: value.acceptedAnswers.joined(separator: ", "))
            }
            if front.mode != .englishToChinese, let meaning = value.chineseMeaning { Text(meaning).lineSpacing(4) }
            if !value.typedAnswer.isEmpty {
                LabeledContent("Your answer", value: value.typedAnswer)
                Text(value.assessment == .matchesSavedAnswer ? "Matches a saved answer" : "Self-assessment required")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let english = value.englishDefinition { Text(english).foregroundStyle(.secondary) }
            if let technical = value.technicalExplanation { Text(technical).foregroundStyle(.secondary) }
            if let example = value.example { Text(example).italic().foregroundStyle(.secondary) }
            if let original = value.originalText { Text(original).foregroundStyle(.secondary) }
        }.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}
#endif
