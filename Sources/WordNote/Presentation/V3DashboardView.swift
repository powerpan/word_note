#if WORDNOTE_V3_VALIDATION
import SwiftData
import SwiftUI
import WordNoteCore

struct DashboardView: View {
    @Environment(\.modelContext) private var context
    @Query private var records: [InputRecordModel]
    @Query private var terms: [TermModel]
    @Query private var cards: [AppSchema.ReviewCardModel]
    @Query private var events: [AppSchema.ReviewEventModel]
    @State private var statistics: ReviewStatisticsSnapshot?
    @State private var resumable: WordNoteV3ReviewSessionSnapshot?
    @State private var errorMessage: String?
    let onOpenReview: () -> Void
    let onOpenInbox: () -> Void

    private var pendingCount: Int {
        records.filter { !$0.analysisPending && ($0.status == .draft || $0.status == .analyzed || $0.analysisFailed) }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Today").font(WordNoteTheme.editorialFont(size: 32, weight: .semibold))
                if let errorMessage { StatusBanner(message: errorMessage, kind: .warning) }
                if let statistics {
                    HStack(alignment: .top, spacing: 32) {
                        metric("Ready cards", statistics.workload.readyCards)
                        metric("New cards", statistics.workload.newCards)
                        metric("Waiting", statistics.workload.waitingRelearningCards)
                        metric("Pending records", pendingCount)
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Review").font(.title2.weight(.semibold))
                            if let resumable {
                                Text("\(resumable.items.count) cards in the current group").foregroundStyle(.secondary)
                            } else {
                                Text("\(terms.count) vocabulary entries").foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(resumable == nil ? "Start Review" : "Continue Review", systemImage: "play.fill", action: onOpenReview)
                            .buttonStyle(.borderedProminent)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 14) {
                        GridRow { Text("Cards answered today"); Text(String(statistics.today.answeredCardCount)).monospacedDigit() }
                        GridRow { Text("Answer attempts"); Text(String(statistics.today.answerCount)).monospacedDigit() }
                        GridRow { Text("Successful completions"); Text(String(statistics.today.completedCardCount)).monospacedDigit() }
                        GridRow {
                            Text("First recall today")
                            if statistics.today.firstRecall.samples == 0 { Text("No answers yet").foregroundStyle(.secondary) }
                            else { Text("\(statistics.today.firstRecall.successes) / \(statistics.today.firstRecall.samples)") }
                        }
                        if let next = statistics.workload.nextRelearningAt {
                            GridRow { Text("Next relearning"); Text(next.formatted(date: .abbreviated, time: .shortened)) }
                        }
                    }.font(.subheadline)
                    if statistics.today.hasEstimatedOrder { Text("Some historical answer ordering is estimated.").font(.caption).foregroundStyle(.secondary) }
                    Text("\(statistics.workload.buriedCards) deferred related cards / \(statistics.workload.suspendedCards) suspended / \(statistics.workload.missingAnswerCards) missing answers")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        Text("Inbox").font(.title2.weight(.semibold))
                        Spacer()
                        Button("Open Inbox", systemImage: "tray", action: onOpenInbox)
                    }
                    ForEach(records.filter { !$0.analysisPending && $0.status == .analyzed }.sorted { $0.updatedAt > $1.updatedAt }.prefix(5), id: \.id) { record in
                        HStack {
                            Text(record.rawText).lineLimit(2)
                            Spacer()
                            Text(record.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                    if pendingCount == 0 { Text("Inbox is clear").foregroundStyle(.secondary) }
                } else if errorMessage == nil { ProgressView() }
            }.padding(28).frame(maxWidth: 1040, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }.background(WordNoteTheme.canvas)
        .onAppear(perform: refresh)
        .onChange(of: cards.map { "\($0.id):\($0.revision)" }) { refresh() }
        .onChange(of: events.count) { refresh() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func metric(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(count.formatted()).font(.system(size: 30, weight: .semibold)).monospacedDigit()
            Text(title).font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refresh() {
        do {
            let service = try WordNoteV3ReviewService(container: context.container)
            statistics = try service.statistics(studyTimeZoneID: TimeZone.current.identifier)
            resumable = try service.resumableSession()
            errorMessage = nil
        } catch { statistics = nil; errorMessage = error.localizedDescription }
    }
}
#endif
