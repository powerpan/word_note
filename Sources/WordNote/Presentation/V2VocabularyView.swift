#if WORDNOTE_V2_VALIDATION
import SwiftData
import SwiftUI
import WordNoteCore

struct V2VocabularyView: View {
    @Environment(\.editProtection) private var editProtection
    @Environment(\.captureNavigation) private var captureNavigation
    @Environment(WordNoteDataProtection.self) private var dataProtection
    @Query private var terms: [TermModel]
    @Query private var courses: [CourseModel]
    @Query private var links: [WordNoteSchemaV2.TermCourseLinkModel]
    @Query private var lookups: [WordNoteSchemaV2.LookupEventModel]
    @State private var index = VocabularyBrowseIndex()
    @State private var visible: [VocabularyBrowseItem] = []
    @State private var query = VocabularyBrowseQuery()
    @State private var selection = VocabularySelection()
    @State private var organization: OrganizationSelection?
    @State private var message: String?
    @State private var exportMessage: String?
    @State private var now = Date()
    @State private var isLoaded = false
    @State private var openedTermID: UUID?

    private struct OrganizationSelection: Identifiable {
        let id = UUID()
        let termIDs: Set<UUID>
    }
    private struct TermVersion: Equatable {
        let id: UUID
        let revision: Int
    }

    private var selectedTerm: TermModel? { terms.first { $0.id == (openedTermID ?? selection.focusedID) } }
    private var effectiveBatch: Set<UUID> { selection.batchIDs.intersection(Set(visible.map(\.id))) }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                listPane.frame(width: min(max(proxy.size.width * 0.37, 310), 410))
                Divider()
                if let term = selectedTerm {
                    V2TermDetailSurface(term: term, courses: courses, onOrganize: { organize([term.id]) })
                        .id(term.id).frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView(systemImage: "book", title: openedTermID == nil ? "No Term Selected" : "Term No Longer Available", message: "") { EmptyView() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear { rebuildIndex(); openCapturedTerm() }
        .onChange(of: captureNavigation?.pending) { openCapturedTerm() }
        .onChange(of: terms.map { TermVersion(id: $0.id, revision: $0.revision) }) { rebuildIndex() }
        .onChange(of: links.map(WordNoteSnapshotV2Payload.CourseLink.init)) { rebuildIndex() }
        .onChange(of: lookups.map(WordNoteSnapshotV2Payload.LookupEvent.init)) { rebuildIndex() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            now = date
            refreshVisible()
        }
        .sheet(item: $organization) { request in
            V2VocabularyOrganizationSheet(termIDs: request.termIDs) { counts in
                selection.clearBatch()
                message = "Organized \(counts.changedTerms) terms."
                rebuildIndex()
            }
        }
        .alert("Vocabulary Export", isPresented: Binding(get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportMessage ?? "") }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            V2VocabularyFilters(query: Binding(get: { query }, set: { changeQuery($0) }), courses: courses, tags: index.tags,
                                visibleCount: visible.count, totalCount: terms.count, selectedCount: effectiveBatch.count,
                                allSelected: !visible.isEmpty && effectiveBatch.count == visible.count,
                                onSelectAll: { selection.reconcile(visible.map(\.id)); selection.toggleAll() },
                                onOrganize: { organize(effectiveBatch) }, onExport: export)
                .disabled(dataProtection.isRestoring)
            if openedTermID != nil {
                CaptureNavigationBanner { protectingEdits(editProtection) { openedTermID = nil } }
            }
            if let message {
                HStack(alignment: .top) {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { self.message = nil }.labelStyle(.iconOnly).help("Dismiss status")
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            List(selection: Binding(get: {
                if let openedTermID { return visible.contains { $0.id == openedTermID } ? openedTermID : nil }
                return selection.focusedID
            }, set: { id in
                guard id != nil || openedTermID == nil else { return }
                guard id != selection.focusedID || openedTermID != nil else { return }
                protectingEdits(editProtection) { openedTermID = nil; selection.focusedID = id }
            })) {
                ForEach(visible) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("Select \(item.term.term)", isOn: Binding(
                            get: { effectiveBatch.contains(item.id) },
                            set: { selection.setSelected($0, id: item.id) }
                        )).labelsHidden().toggleStyle(.checkbox).padding(.top, 3)
                        V2VocabularyRow(item: item, courses: courses)
                    }.tag(item.id).padding(.vertical, 6)
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if !isLoaded { ProgressView() }
                else if visible.isEmpty {
                    EmptyStateView(systemImage: "books.vertical", title: terms.isEmpty ? "No Terms Yet" : "No Matches", message: "") { EmptyView() }
                        .allowsHitTesting(false)
                }
            }
        }.background(WordNoteTheme.surface)
    }

    private func changeQuery(_ value: VocabularyBrowseQuery) {
        guard value != query else { return }
        protectingEdits(editProtection) {
            openedTermID = nil
            let scopeChanged = !query.hasSameScope(as: value)
            query = value
            refreshVisible(scopeChanged: scopeChanged)
        }
    }

    private func openCapturedTerm() {
        guard let id = captureNavigation?.takeVocabulary() else { return }
        openedTermID = id
        selection.clearBatch()
        message = nil
    }

    private func rebuildIndex() {
        index = VocabularyBrowseIndex(terms: terms.map(WordNoteSnapshotPayload.Term.init),
                                     courseLinks: links.map(WordNoteSnapshotV2Payload.CourseLink.init),
                                     lookupEvents: lookups.map(WordNoteSnapshotV2Payload.LookupEvent.init))
        isLoaded = true
        refreshVisible()
    }

    private func refreshVisible(scopeChanged: Bool = false) {
        visible = index.matching(query, at: now)
        selection.reconcile(visible.map(\.id), scopeChanged: scopeChanged)
    }

    private func organize(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        protectingEdits(editProtection) { organization = .init(termIDs: ids) }
    }

    private func export(_ selectedOnly: Bool) {
        let ids = selectedOnly ? (effectiveBatch.isEmpty ? Set([selectedTerm?.id].compactMap { $0 }) : effectiveBatch) : Set(visible.map(\.id))
        let values = terms.filter { ids.contains($0.id) }.map(WordNoteSnapshotPayload.Term.init)
        let courseValues = courses.map(WordNoteSnapshotPayload.Course.init)
        let memberships = Dictionary(uniqueKeysWithValues: values.map { term in
            (term.id, Set(links.filter { $0.termID == term.id }.map(\.courseID)))
        })
        guard !values.isEmpty, values.count == ids.count else { exportMessage = "The selection changed. Select the terms again."; return }
        Task {
            guard let url = await DataFilePicker.exportURL(csvCount: values.count) else { return }
            do {
                try await dataProtection.exportVocabulary(terms: values, courses: courseValues, courseMemberships: memberships, to: url)
                exportMessage = "Exported \(values.count) vocabulary entries."
            } catch { exportMessage = error.localizedDescription }
        }
    }
}

private struct V2VocabularyRow: View {
    let item: VocabularyBrowseItem
    let courses: [CourseModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.term.term).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(item.chineseSummary.isEmpty ? "No Chinese meaning" : item.chineseSummary)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            let names = courses.filter { item.courseIDs.contains($0.id) }.map(\.courseName).sorted()
            Text(([MasteryLevel(rawValue: item.term.masteryLevelRaw)?.displayTitle ?? item.term.masteryLevelRaw] + names).joined(separator: ", "))
                .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
