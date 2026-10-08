#if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
import SwiftData
import SwiftUI
import WordNoteCore

struct V2InboxView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.savedChangeHistory) private var undoHistory
    @Environment(\.editProtection) private var editProtection
    @Environment(\.captureNavigation) private var captureNavigation
    @Environment(\.learningWorkspace) private var workspace
    @Environment(QuickAddAnalysisQueue.self) private var queue
    @Environment(WordNoteDataProtection.self) private var dataProtection
    @Query private var records: [InputRecordModel]
    @Query private var candidates: [CandidateTermModel]
    @Query private var courses: [CourseModel]
    @State private var index = InboxBrowseIndex()
    @State private var localState = InboxWorkspaceState()
    @State private var visible = InboxBrowseIndex().matching(.init())
    @State private var confirmationPlan: WordNoteV2ConfirmationPlan?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    private var viewState: InboxWorkspaceState {
        get { workspace?.inbox ?? localState }
        nonmutating set { if let workspace { workspace.inbox = newValue } else { localState = newValue } }
    }
    private var query: InboxBrowseQuery { get { viewState.query } nonmutating set { viewState.query = newValue } }
    private var selection: InboxSelection { get { viewState.selection } nonmutating set { viewState.selection = newValue } }
    private var openedRecordID: UUID? { get { viewState.openedRecordID } nonmutating set { viewState.openedRecordID = newValue } }
    @SceneStorage("v2InboxHandledExpanded") private var handledExpanded = false
    #if WORDNOTE_V3_VALIDATION
    @SceneStorage("workspace.inbox.width") private var listWidth = WorkspaceColumnRules.inbox.preferred
    #endif

    private struct Version: Equatable {
        let id: UUID
        let revision: Int
    }

    private var selectedRecord: InputRecordModel? { records.first { $0.id == (openedRecordID ?? selection.focusedID) } }

    var body: some View {
        columns
        .frame(minWidth: 800, minHeight: 600)
        .onAppear { rebuildIndex(); openCapturedRecord() }
        .onChange(of: captureNavigation?.pending) { openCapturedRecord() }
        .onChange(of: records.map { Version(id: $0.id, revision: $0.revision) }) {
            rebuildIndex()
            guard !WordNoteWriteGate.isBlocked(context) else { return }
            do { try queue.refreshJobs() } catch { errorMessage = error.localizedDescription }
        }
        .onChange(of: candidates.map { Version(id: $0.id, revision: $0.revision) }) { rebuildIndex() }
        .onChange(of: handledExpanded) { refreshVisible() }
        .onChange(of: query) { refreshVisible() }
        .sheet(item: $confirmationPlan) { plan in
            V2ConfirmationPreview(plan: plan) { result in
                selection.clearBatch()
                showSuccess(AppLocalization.format("Saved or linked %lld candidates; ignored %lld.", result.counts.candidates - result.counts.ignoredCandidates, result.counts.ignoredCandidates))
            }
        }
    }

    @ViewBuilder private var columns: some View {
        #if WORDNOTE_V3_VALIDATION
        WorkspaceSplitView(preferredWidth: $listWidth, rules: .inbox, label: "Inbox list width") {
            listPane
        } detail: {
            detailPane
        }
        #else
        GeometryReader { proxy in
            HStack(spacing: 0) {
                listPane.frame(width: min(max(proxy.size.width * 0.37, 310), 410))
                Divider()
                detailPane.frame(minWidth: selectedRecord == nil ? 0 : 440)
            }
        }
        #endif
    }

    @ViewBuilder private var detailPane: some View {
        if let record = selectedRecord {
            V2InputRecordDetailView(record: record, course: courses.first { $0.id == record.courseID },
                candidates: candidates.filter { $0.inputRecordID == record.id },
                onAnalyze: { analyze(record.id) }, onIgnore: { ignoreRecord(record.id) }, onDelete: { deleteRecord(record.id) },
                onConfirm: confirmCandidates, onIgnoreCandidates: ignoreCandidates,
                onManualSave: { showSuccess("Saved to Vocabulary.") }, advancesAfterConfirmation: openedRecordID == nil)
                .id(record.id).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(systemImage: "tray", title: openedRecordID != nil ? "Record No Longer Available" : (visible.active.isEmpty ? "No Active Records" : "No Record Selected"), message: "") { EmptyView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            V2InboxFilters(query: Binding(get: { query }, set: { changeQuery($0) }), courses: courses,
                activeCount: visible.active.count, handledCount: visible.handled.count,
                selectedCounts: visible.selectedCounts(selection.batchIDs),
                allSelected: !selection.confirmableIDs.isEmpty && selection.confirmableIDs.isSubset(of: selection.batchIDs),
                canSelect: !selection.confirmableIDs.isEmpty, onSelectAll: { selection.toggleAll() }, onConfirm: confirmSelectedRecords)
                .disabled(dataProtection.isRestoring)
            if openedRecordID != nil {
                CaptureNavigationBanner(title: workspace == nil ? "Opened from Quick Add" : "Linked input record") {
                    protectingEdits(editProtection) { openedRecordID = nil }
                }
            }
            if let errorMessage { StatusBanner(message: errorMessage, kind: .warning).padding(.horizontal, 16).padding(.bottom, 8) }
            if let statusMessage {
                HStack(alignment: .top) {
                    Text(AppLocalization.text(statusMessage)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { self.statusMessage = nil }.labelStyle(.iconOnly).help("Dismiss status")
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            V2AnalysisTasksView(queue: queue).disabled(dataProtection.isRestoring)
            RememberingList(selection: Binding(get: {
                if let openedRecordID { return selection.visibleIDs.contains(openedRecordID) ? openedRecordID : nil }
                return selection.focusedID
            }, set: { id in
                guard id != nil || openedRecordID == nil else { return }
                guard id != selection.focusedID || openedRecordID != nil else { return }
                protectingEdits(editProtection) { openedRecordID = nil; selection.focusedID = id }
            }), anchor: Binding(get: { viewState.scrollID }, set: { viewState.scrollID = $0 }), ids: selection.visibleIDs.sorted { $0.uuidString < $1.uuidString }) {
                ForEach(visible.active) { item in
                    row(item, selection: item.canConfirm ? Binding(
                        get: { selection.batchIDs.contains(item.id) },
                        set: { selection.setSelected($0, id: item.id) }
                    ) : nil).tag(item.id).rememberListRow(item.id)
                }
                if !visible.handled.isEmpty {
                    DisclosureGroup(isExpanded: Binding(get: { handledExpanded }, set: { value in
                        protectingEdits(editProtection) { handledExpanded = value }
                    })) {
                        ForEach(visible.handled) { item in row(item, selection: nil).tag(item.id).rememberListRow(item.id) }
                    } label: { Label("Handled (\(visible.handled.count))", systemImage: "archivebox") }
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if visible.active.isEmpty && visible.handled.isEmpty {
                    EmptyStateView(systemImage: "tray", title: "No Matches", message: "") { EmptyView() }.allowsHitTesting(false)
                }
            }
        }.background(WordNoteTheme.surface)
    }

    private func row(_ item: InboxBrowseItem, selection: Binding<Bool>?) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.record.rawText).font(.headline).lineLimit(1)
                if !item.isFailed || item.previewText != nil {
                    Text(item.localizedPreview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if item.isFailed { Label("Analysis failed", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(WordNoteTheme.amber) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let selection {
                Toggle("Select \(item.record.rawText)", isOn: selection).labelsHidden().toggleStyle(.checkbox)
            } else if item.isHandled {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary).accessibilityLabel("Handled")
            }
        }.padding(.vertical, 5)
    }

    private func rebuildIndex() {
        let grouped = Dictionary(grouping: candidates, by: \.inputRecordID)
        index = .init(items: records.map { .init(record: $0, candidates: grouped[$0.id, default: []]) })
        refreshVisible()
    }

    private func refreshVisible(scopeChanged: Bool = false) {
        visible = index.matching(query)
        selection.reconcile(active: visible.active.map(\.id), handled: handledExpanded ? visible.handled.map(\.id) : [],
                            confirmable: visible.confirmableIDs, scopeChanged: scopeChanged)
    }

    private func changeQuery(_ value: InboxBrowseQuery) {
        guard value != query else { return }
        protectingEdits(editProtection) { openedRecordID = nil; query = value; refreshVisible(scopeChanged: true) }
    }

    private func openCapturedRecord() {
        guard let id = captureNavigation?.takeInputRecord() else { return }
        openedRecordID = id
        selection.clearBatch()
        errorMessage = nil
        statusMessage = nil
    }

    private func confirmSelectedRecords() {
        let ids = selection.batchIDs
        protectingEdits(editProtection) {
            perform {
                rebuildIndex()
                guard !ids.isEmpty, ids.isSubset(of: visible.confirmableIDs) else { throw WordNoteV2ConfirmationPlanError.stalePlan }
                try presentConfirmation(visible.active.filter { ids.contains($0.id) }.flatMap(\.selections))
            }
        }
    }

    private func confirmCandidates(_ ids: Set<UUID>) {
        protectingEdits(editProtection) { perform { try presentConfirmation(currentSelections(ids)) } }
    }

    private func presentConfirmation(_ selected: [WordNoteV2CandidateSelection]) throws {
        confirmationPlan = try AppContentService(container: context.container).makeConfirmationPlan(selected)
        statusMessage = nil
    }

    private func currentSelections(_ ids: Set<UUID>) throws -> [WordNoteV2CandidateSelection] {
        rebuildIndex()
        let items: [InboxBrowseItem]
        if let openedRecordID {
            guard let record = records.first(where: { $0.id == openedRecordID }) else { throw AppContentError.missingEntity }
            items = [InboxBrowseItem(record: record, candidates: candidates.filter { $0.inputRecordID == openedRecordID })]
        } else { items = visible.active }
        let values = items.flatMap(\.selections).filter { ids.contains($0.id) }
        guard !ids.isEmpty, values.count == ids.count else { throw WordNoteV2ConfirmationPlanError.stalePlan }
        return values
    }

    private func ignoreCandidates(_ ids: Set<UUID>) {
        protectingEdits(editProtection) {
            perform {
                try AppContentService(container: context.container, undoHistory: undoHistory).ignoreCandidates(currentSelections(ids))
                showSuccess(AppLocalization.format("Ignored %lld candidates.", ids.count))
            }
        }
    }

    private func ignoreRecord(_ id: UUID) {
        protectingEdits(editProtection) {
            perform {
                guard let value = records.first(where: { $0.id == id }) else { throw AppContentError.missingEntity }
                try AppContentService(container: context.container, undoHistory: undoHistory).ignoreInputRecord(id, expectedRevision: value.revision)
                showSuccess("Input record ignored.")
            }
        }
    }

    private func deleteRecord(_ id: UUID) {
        protectingEdits(editProtection) {
            perform {
                guard let value = records.first(where: { $0.id == id }) else { throw AppContentError.missingEntity }
                try AppContentService(container: context.container).deleteInputRecord(id, expectedRevision: value.revision)
                showSuccess("Input record deleted.")
            }
        }
    }

    private func analyze(_ id: UUID) {
        protectingEdits(editProtection) {
            perform {
                guard let value = records.first(where: { $0.id == id }) else { throw AppContentError.missingEntity }
                try queue.retry(id, expectedRevision: value.revision)
                showSuccess("Added to analysis tasks.")
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription; statusMessage = nil }
    }

    private func showSuccess(_ message: String) { statusMessage = message; errorMessage = nil; rebuildIndex() }
}
#endif
