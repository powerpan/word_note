#if WORDNOTE_V3_VALIDATION
import SwiftData
import SwiftUI
import WordNoteCore

struct V3LearningOverviewSurface<Content: View>: View {
    @Environment(\.modelContext) private var context
    @Environment(WordNoteDataProtection.self) private var protection
    @Query private var courses: [CourseModel]
    @Query private var terms: [TermModel]
    @Query private var records: [InputRecordModel]
    @Query private var candidates: [CandidateTermModel]
    @Query private var cards: [AppSchema.ReviewCardModel]
    @Query private var events: [AppSchema.ReviewEventModel]
    @Query private var sessions: [AppSchema.ReviewSessionModel]
    @Query private var links: [AppSchema.TermCourseLinkModel]
    @Query private var occurrences: [AppSchema.TermOccurrenceModel]
    @State private var snapshot: LearningOverviewSnapshot?
    @State private var errorMessage: String?
    let courseID: UUID?
    let mode: ReviewMode
    @ViewBuilder let content: (LearningOverviewSnapshot) -> Content

    private var revisions: [String] {
        courses.map { "course:\($0.id):\($0.revision)" }
        + terms.map { "term:\($0.id):\($0.revision)" }
        + records.map { "record:\($0.id):\($0.revision)" }
        + candidates.map { "candidate:\($0.id):\($0.revision)" }
        + cards.map { "card:\($0.id):\($0.revision)" }
        + sessions.map { "session:\($0.id):\($0.revision)" }
    }

    var body: some View {
        Group {
            if protection.isRestoring { ProgressView() }
            else if let errorMessage { StatusBanner(message: errorMessage, kind: .warning) }
            else if let snapshot { content(snapshot) }
            else { ProgressView() }
        }
        .onAppear(perform: refresh)
        .onChange(of: mode) { refresh() }
        .onChange(of: courseID) { refresh() }
        .onChange(of: revisions) { refresh() }
        .onChange(of: events.map { "\($0.id):\($0.invalidatedAt?.timeIntervalSince1970 ?? 0)" }) { refresh() }
        .onChange(of: links.map(WordNoteSnapshotV2Payload.CourseLink.init)) { refresh() }
        .onChange(of: occurrences.map(WordNoteSnapshotV2Payload.Occurrence.init)) { refresh() }
        .onChange(of: protection.isRestoring) { refresh() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func refresh() {
        guard !protection.isRestoring else { snapshot = nil; return }
        do {
            snapshot = try WordNoteV3ReviewService(container: context.container).learningOverview(courseID: courseID,
                mode: mode, studyTimeZoneID: TimeZone.current.identifier)
            errorMessage = nil
        } catch { snapshot = nil; errorMessage = error.localizedDescription }
    }
}

struct V3LearningSummary: View {
    let statistics: ReviewStatisticsSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                metric("Ready", statistics.workload.readyCards)
                metric("New", statistics.workload.newCards)
                metric("Waiting", statistics.workload.waitingRelearningCards)
                metric("Completed today", statistics.today.completedCardCount)
            }
            HStack {
                Text("First recall today")
                if statistics.today.firstRecall.samples == 0 { Text("No answers yet").foregroundStyle(.secondary) }
                else { Text("\(statistics.today.firstRecall.successes) / \(statistics.today.firstRecall.samples)").monospacedDigit() }
                Spacer()
                Text("\(statistics.today.answerCount) answers").foregroundStyle(.secondary)
            }.font(.subheadline)
            if let next = statistics.workload.nextRelearningAt {
                LabeledContent("Next relearning", value: next.formatted(date: .abbreviated, time: .shortened)).font(.caption)
            }
            if statistics.today.hasEstimatedOrder {
                Text("Some historical answer ordering is estimated.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(count.formatted()).font(.system(size: 26, weight: .semibold)).monospacedDigit()
            Text(AppLocalization.text(title)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LearningLinkRow: View {
    let title: String
    var subtitle: String? = nil
    var detail: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline).lineLimit(2)
                    if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct LearningCardRows: View {
    let cards: [ReviewCardLearningItem]
    let open: (LearningRoute) -> Void
    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        if cards.isEmpty { Text("No cards in this state").foregroundStyle(.secondary).padding(.vertical, 12) }
        ForEach(cards) { item in
            LearningLinkRow(title: item.term.term, subtitle: item.term.chineseMeaning,
                detail: item.waitingUntil?.formatted(date: .omitted, time: .shortened) ?? AppLocalization.format("Mastery: %@", AppLocalization.text(item.card.schedule.masteryLevel.displayTitle))) {
                open(.term(item.term.id, cardID: item.id))
            }.rememberListRow(item.id)
            Divider()
        }
      }
    }
}
#endif
