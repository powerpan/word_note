#if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
import SwiftData
import SwiftUI
import WordNoteCore

struct V2VocabularyView: View {
    @Environment(\.editProtection) private var editProtection
    @Environment(\.captureNavigation) private var captureNavigation
    @Environment(\.learningWorkspace) private var workspace
    @Environment(\.modelContext) private var context
    @Environment(WordNoteDataProtection.self) private var dataProtection
    @Query private var terms: [TermModel]
    @Query private var courses: [CourseModel]
    @Query private var links: [AppSchema.TermCourseLinkModel]
    @Query private var lookups: [AppSchema.LookupEventModel]
    @State private var index = VocabularyBrowseIndex()
    @State private var visible: [VocabularyBrowseItem] = []
    @State private var localState = VocabularyWorkspaceState()
    @State private var organization: OrganizationSelection?
    @State private var message: String?
    @State private var exportMessage: String?
    @State private var now = Date()
    @State private var isLoaded = false
    #if WORDNOTE_V3_VALIDATION
    @SceneStorage("workspace.vocabulary.width") private var listWidth = WorkspaceColumnRules.vocabulary.preferred
    @Query private var cards: [AppSchema.ReviewCardModel]
    @State private var cardIndex: ReviewCardLearningIndex?
    #endif
    private var viewState: VocabularyWorkspaceState {
        get { workspace?.vocabulary ?? localState }
        nonmutating set { if let workspace { workspace.vocabulary = newValue } else { localState = newValue } }
    }
    private var query: VocabularyBrowseQuery { get { viewState.query } nonmutating set { viewState.query = newValue } }
    private var selection: VocabularySelection { get { viewState.selection } nonmutating set { viewState.selection = newValue } }
    private var openedTermID: UUID? { get { viewState.openedTermID } nonmutating set { viewState.openedTermID = newValue } }

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
        columns
        .frame(minWidth: 800, minHeight: 600)
        .onAppear { rebuildIndex(); openCapturedTerm() }
        .onChange(of: captureNavigation?.pending) { openCapturedTerm() }
        .onChange(of: query) { refreshVisible() }
        .onChange(of: terms.map { TermVersion(id: $0.id, revision: $0.revision) }) { rebuildIndex() }
        .onChange(of: links.map(WordNoteSnapshotV2Payload.CourseLink.init)) { rebuildIndex() }
        .onChange(of: lookups.map(WordNoteSnapshotV2Payload.LookupEvent.init)) { rebuildIndex() }
        #if WORDNOTE_V3_VALIDATION
        .onChange(of: cards.map { TermVersion(id: $0.id, revision: $0.revision) }) { rebuildIndex() }
        .onChange(of: viewState.cards) { refreshVisible() }
        #endif
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            now = date
            #if WORDNOTE_V3_VALIDATION
            rebuildCardIndex()
            #endif
            refreshVisible()
        }
        .sheet(item: $organization) { request in
            V2VocabularyOrganizationSheet(termIDs: request.termIDs) { counts in
                selection.clearBatch()
                message = AppLocalization.format("Organized %lld terms.", counts.changedTerms)
                rebuildIndex()
            }
        }
        .alert("Vocabulary Export", isPresented: Binding(get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportMessage ?? "") }
    }

    @ViewBuilder private var columns: some View {
        #if WORDNOTE_V3_VALIDATION
        WorkspaceSplitView(preferredWidth: $listWidth, rules: .vocabulary, label: "Vocabulary list width") {
            listPane
        } detail: {
            detailPane
        }
        #else
        GeometryReader { proxy in
            HStack(spacing: 0) {
                listPane.frame(width: min(max(proxy.size.width * 0.37, 310), 410))
                Divider()
                detailPane.frame(minWidth: selectedTerm == nil ? 0 : 400)
            }
        }
        #endif
    }

    @ViewBuilder private var detailPane: some View {
        if let term = selectedTerm {
            V2TermDetailSurface(term: term, courses: courses, requestedCardID: viewState.openedCardID, onOrganize: { organize([term.id]) })
                .id(term.id).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(systemImage: "book", title: openedTermID == nil ? "No Term Selected" : "Term No Longer Available", message: "") { EmptyView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            V2VocabularyFilters(query: Binding(get: { query }, set: { changeQuery($0) }), courses: courses, tags: index.tags,
                                visibleCount: visible.count, totalCount: terms.count, selectedCount: effectiveBatch.count,
                                allSelected: !visible.isEmpty && effectiveBatch.count == visible.count,
                                onSelectAll: { selection.reconcile(visible.map(\.id)); selection.toggleAll() },
                                onOrganize: { organize(effectiveBatch) }, onExport: export)
                .disabled(dataProtection.isRestoring)
            #if WORDNOTE_V3_VALIDATION
            V3VocabularyCardFilters(query: Binding(get: { viewState.cards }, set: { value in
                protectingEdits(editProtection) {
                    viewState.cards = value; openedTermID = nil; viewState.openedCardID = nil
                    refreshVisible(scopeChanged: true)
                }
            })).padding(.horizontal, 16).padding(.bottom, 12)
            #endif
            if openedTermID != nil {
                CaptureNavigationBanner(title: workspace == nil ? "Opened from Quick Add" : "Linked vocabulary") {
                    protectingEdits(editProtection) { openedTermID = nil; viewState.openedCardID = nil }
                }
            }
            if let message {
                HStack(alignment: .top) {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { self.message = nil }.labelStyle(.iconOnly).help("Dismiss status")
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            RememberingList(selection: Binding(get: {
                if let openedTermID { return visible.contains { $0.id == openedTermID } ? openedTermID : nil }
                return selection.focusedID
            }, set: { id in
                guard id != nil || openedTermID == nil else { return }
                guard id != selection.focusedID || openedTermID != nil else { return }
                protectingEdits(editProtection) { openedTermID = nil; viewState.openedCardID = nil; selection.focusedID = id }
            }), anchor: Binding(get: { viewState.scrollID }, set: { viewState.scrollID = $0 }), ids: visible.map(\.id)) {
                ForEach(visible) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("Select \(item.term.term)", isOn: Binding(
                            get: { effectiveBatch.contains(item.id) },
                            set: { selection.setSelected($0, id: item.id) }
                        )).labelsHidden().toggleStyle(.checkbox).padding(.top, 3)
                        V2VocabularyRow(item: item, courses: courses)
                    }.tag(item.id).padding(.vertical, 6).rememberListRow(item.id)
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
            viewState.openedCardID = nil
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
        #if WORDNOTE_V3_VALIDATION
        rebuildCardIndex()
        #endif
        refreshVisible()
    }

    private func refreshVisible(scopeChanged: Bool = false) {
        #if WORDNOTE_V3_VALIDATION
        var contentQuery = query
        contentQuery.mastery = nil
        visible = index.matching(contentQuery, at: now)
        if viewState.cards.isActive {
            let ids = Set(cardIndex?.matching(query: viewState.cards).map { $0.term.id } ?? [])
            visible = visible.filter { ids.contains($0.id) }
        }
        #else
        visible = index.matching(query, at: now)
        #endif
        selection.reconcile(visible.map(\.id), scopeChanged: scopeChanged)
    }

    #if WORDNOTE_V3_VALIDATION
    private func rebuildCardIndex() {
        do {
            cardIndex = try WordNoteV3ReviewService(container: context.container)
                .cardLearningIndex(studyTimeZoneID: TimeZone.current.identifier, at: now)
        } catch { cardIndex = nil; message = error.localizedDescription }
    }
    #endif

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
        guard !values.isEmpty, values.count == ids.count else { exportMessage = AppLocalization.text("The selection changed. Select the terms again."); return }
        Task {
            guard let url = await DataFilePicker.exportURL(csvCount: values.count) else { return }
            do {
                try await dataProtection.exportVocabulary(terms: values, courses: courseValues, courseMemberships: memberships, to: url)
                exportMessage = AppLocalization.format("Exported %lld vocabulary entries.", values.count)
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
            Text(item.chineseSummary.isEmpty ? AppLocalization.text("No Chinese meaning") : item.chineseSummary)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            let names = courses.filter { item.courseIDs.contains($0.id) }.map(\.courseName).sorted()
            #if WORDNOTE_V3_VALIDATION
            Text(names.isEmpty ? AppLocalization.text("No course") : names.joined(separator: ", "))
                .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            #else
            Text(([AppLocalization.text(MasteryLevel(rawValue: item.term.masteryLevelRaw)?.displayTitle ?? item.term.masteryLevelRaw)] + names).joined(separator: ", "))
                .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            #endif
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
