#if WORDNOTE_V2_VALIDATION
import SwiftUI
import WordNoteCore

struct V2AnalysisTasksView: View {
    let queue: WordNoteV2AnalysisQueue
    @State private var expanded = false
    @State private var errorMessage: String?
    @State private var pendingCancellation: WordNoteV2AnalysisJob?

    init(queue: WordNoteV2AnalysisQueue, startsExpanded: Bool = false) {
        self.queue = queue
        _expanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        if !queue.jobs.isEmpty || queue.isSuspended {
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if queue.isSuspended {
                            Button("Resume Analysis", systemImage: "play.fill") { perform { _ = try queue.resumePendingAnalyses() } }
                        } else {
                            Button("Pause Analysis", systemImage: "pause.fill") { perform { try queue.pause() } }
                        }
                        ForEach(queue.jobs) { job in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(job.rawText).lineLimit(1)
                                    Spacer()
                                    if job.state == .queued || job.state == .running {
                                        Button {
                                            if job.state == .running { pendingCancellation = job }
                                            else { perform { try queue.cancel(job.id, expectedRevision: job.revision) } }
                                        } label: { Image(systemName: "xmark.circle") }
                                            .help("Cancel analysis").accessibilityLabel("Cancel analysis")
                                    } else {
                                        Button { perform { try queue.retry(job.id, expectedRevision: job.revision) } } label: { Image(systemName: "arrow.clockwise") }
                                            .help("Retry analysis").accessibilityLabel("Retry analysis")
                                    }
                                }
                                Text(job.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                if let next = job.nextAttemptAt {
                                    Text("Retry after \(next.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                                }
                                if let message = job.errorSummary { Text(message).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if let errorMessage { StatusBanner(message: errorMessage, kind: .warning) }
                        else if let error = queue.errorMessage { StatusBanner(message: error, kind: .warning) }
                    }
                    .padding(.top, 8)
                }
                .frame(maxHeight: 220)
            } label: {
                Label("Analysis Tasks (\(queue.jobs.count))", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.weight(.medium))
            }
            .padding(14)
            .background(WordNoteTheme.surface)
            .confirmationDialog("Stop waiting for this analysis?", isPresented: Binding(
                get: { pendingCancellation != nil }, set: { if !$0 { pendingCancellation = nil } }
            ), presenting: pendingCancellation) { job in
                Button("Stop Local Analysis") { perform { try queue.cancel(job.id, expectedRevision: job.revision) } }
            } message: { _ in Text("A request already sent to DeepSeek may still be billed. Its result will not be applied after cancellation.") }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}
#endif
