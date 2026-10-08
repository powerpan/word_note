#if WORDNOTE_V2_VALIDATION
import SwiftData
import SwiftUI
import WordNoteCore

struct V2CandidateReviewView: View {
    @Environment(\.editProtection) private var editProtection
    @Query private var terms: [TermModel]
    let record: InputRecordModel
    let candidates: [CandidateTermModel]
    let onConfirm: (Set<UUID>) -> Void
    let onIgnore: (Set<UUID>) -> Void
    let onManualSave: () -> Void
    @State private var selection = InboxCandidateSelection()
    @State private var editingIDs: Set<UUID> = []
    @State private var editedIDs: Set<UUID> = []
    @State private var manualPresented = false
    @State private var handledExpanded = false

    private var pending: [CandidateTermModel] {
        candidates.filter { $0.status == .pending }.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
    }
    private var handled: [CandidateTermModel] { candidates.filter { $0.status != .pending } }
    private var selected: Set<UUID> { selection.selectedIDs.intersection(Set(pending.map(\.id))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Candidates").font(.headline)
                    Text("\(pending.count) pending, \(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Select All", systemImage: "checklist") { selection.toggleAll() }
                    .labelStyle(.iconOnly).help("Select or clear pending candidates").disabled(pending.isEmpty || manualPresented)
                Button("Add Manually", systemImage: "plus") {
                    protectingEdits(editProtection) { manualPresented.toggle() }
                }.labelStyle(.iconOnly).help("Add term manually").disabled(record.status == .completed)
            }
            V2CandidateDraftEditor(candidates: pending, record: record,
                selectedIDs: Binding(get: { selection.selectedIDs }, set: { selection.select($0) }), editedIDs: $editedIDs,
                editingIDs: editingIDs, existingTerms: Set(terms.map(\.normalizedTerm)), onToggleEditing: toggleEditing,
                onConfirm: { onConfirm([$0]) }, onIgnore: { onIgnore([$0]) })
                .disabled(manualPresented)
            if pending.isEmpty && editedIDs.isEmpty {
                Text(record.status == .completed ? "All candidates handled." : "No pending candidates.").foregroundStyle(.secondary)
            }
            if !pending.isEmpty {
                HStack {
                    Button(selected.count == pending.count ? "Confirm & Next" : "Confirm Selected", systemImage: "checkmark.circle") { onConfirm(selected) }
                        .disabled(selected.isEmpty || manualPresented)
                    Button("Ignore Selected", systemImage: "archivebox") { onIgnore(selected) }
                        .labelStyle(.iconOnly).help("Ignore selected candidates").disabled(selected.isEmpty || manualPresented)
                    Spacer()
                }
            }
            if manualPresented {
                ManualTermEditor(record: record, onSaved: { _ in manualPresented = false; onManualSave() },
                                 onCancel: { manualPresented = false })
            }
            if !handled.isEmpty {
                DisclosureGroup("Handled Candidates (\(handled.count))", isExpanded: $handledExpanded) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(handled.sorted { $0.createdAt < $1.createdAt }, id: \.id) { candidate in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(candidate.term).font(.headline)
                                    Spacer()
                                    Text(candidate.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                }
                                if let meaning = candidate.chineseMeaning { Text(meaning).textSelection(.enabled).lineSpacing(4) }
                                if let definition = candidate.englishDefinition { Text(definition).foregroundStyle(.secondary).textSelection(.enabled) }
                            }
                        }
                    }.padding(.top, 10)
                }
            }
        }
        .onAppear(perform: reconcile)
        .onChange(of: candidates.map(WordNoteSnapshotPayload.Candidate.init)) { reconcile() }
    }

    private func toggleEditing(_ id: UUID) {
        protectingEdits(editProtection) {
            if editingIDs.contains(id) { editingIDs.remove(id) } else { editingIDs.insert(id) }
        }
    }

    private func reconcile() {
        selection.reconcile(candidates.map(WordNoteSnapshotPayload.Candidate.init))
        if editedIDs.isEmpty { editingIDs.formIntersection(selection.pendingIDs) }
    }
}
#endif
