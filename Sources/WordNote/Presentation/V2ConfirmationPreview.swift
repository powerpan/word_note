#if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
import SwiftData
import SwiftUI
import WordNoteCore

struct V2ConfirmationPreview: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.savedChangeHistory) private var undoHistory
    @Environment(\.dismiss) private var dismiss
    @State private var plan: WordNoteV2ConfirmationPlan
    @State private var choices = WordNoteV2ConfirmationChoices()
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var needsRefresh = false
    let onCommitted: (WordNoteV2ConfirmationResult) -> Void

    init(plan: WordNoteV2ConfirmationPlan, onCommitted: @escaping (WordNoteV2ConfirmationResult) -> Void) {
        _plan = State(initialValue: plan)
        self.onCommitted = onCommitted
    }

    private var resolved: Result<WordNoteV2ConfirmationResolution, Error> { Result { try plan.resolve(choices) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Confirm Candidates").font(.title2.bold())
                Spacer()
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly).help("Close preview").keyboardShortcut(.cancelAction)
            }.padding(20)
            switch resolved {
            case .success(let resolution):
                summary(resolution.counts)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(plan.groups) { group in
                            V2ConfirmationGroupView(
                                plan: plan, group: group, choices: $choices,
                                conflict: resolution.conflicts.first { $0.id == group.id }?.message
                            )
                            Divider()
                        }
                    }.padding(20)
                }
            case .failure(let error):
                StatusBanner(message: error.localizedDescription, kind: .warning).padding(20)
                Spacer()
            }
            if let errorMessage { StatusBanner(message: errorMessage, kind: .warning).padding(.horizontal, 20) }
            if let statusMessage { Text(AppLocalization.text(statusMessage)).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20) }
            Divider().padding(.top, 12)
            HStack {
                Button("Refresh Preview", systemImage: "arrow.clockwise", action: refresh)
                    .labelStyle(.iconOnly).help("Refresh preview and reset choices")
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Confirm", systemImage: "checkmark.circle", action: commit)
                    .buttonStyle(.borderedProminent)
                    .disabled(needsRefresh || !canCommit)
            }.padding(20)
        }
        .frame(width: 720, height: 600)
        .background(WordNoteTheme.canvas)
        .interactiveDismissDisabled()
    }

    private var canCommit: Bool {
        guard case .success(let resolution) = resolved else { return false }
        return resolution.conflicts.isEmpty
    }

    private func summary(_ counts: WordNoteV2ConfirmationResolution.Counts) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(counts.records) records, \(counts.candidates) candidates").font(.headline)
            Text("\(counts.newTerms) new terms, \(counts.linkedCandidates) candidate links, \(counts.supplementedTerms) supplemented, \(counts.ignoredCandidates) ignored")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if counts.conflicts > 0 {
                Label("\(counts.conflicts) unresolved conflicts", systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(WordNoteTheme.amber)
            }
        }.padding(.horizontal, 20).padding(.bottom, 16)
    }

    private func refresh() {
        do {
            plan = try AppContentService(container: modelContext.container).refreshConfirmationPlan(plan)
            choices = .init()
            needsRefresh = false
            errorMessage = nil
            statusMessage = "Preview refreshed. Choices reset."
        } catch {
            needsRefresh = true
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func commit() {
        do {
            let result = try AppContentService(container: modelContext.container, undoHistory: undoHistory)
                .commitConfirmationPlan(plan, choices: choices)
            dismiss()
            onCommitted(result)
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
            if error as? WordNoteV2ConfirmationPlanError == .stalePlan { needsRefresh = true }
        }
    }
}
#endif
