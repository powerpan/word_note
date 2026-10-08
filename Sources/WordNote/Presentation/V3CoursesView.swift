#if WORDNOTE_V3_VALIDATION
import SwiftData
import SwiftUI
import WordNoteCore

struct V3CoursesView: View {
    @Environment(\.learningWorkspace) private var workspace
    @Environment(\.editProtection) private var protection
    @Query(sort: \CourseModel.courseName) private var courses: [CourseModel]
    @Query private var links: [AppSchema.TermCourseLinkModel]
    @Query private var records: [InputRecordModel]
    @State private var editing = false
    @State private var creating = false
    @State private var errorMessage: String?
    @SceneStorage("workspace.courses.width") private var listWidth = WorkspaceColumnRules.courses.preferred
    private var selected: CourseModel? { courses.first { $0.id == workspace?.courseID } }
    private var termCount: Int { Set(links.filter { $0.courseID == selected?.id }.map(\.termID)).count }
    private var pendingCount: Int {
        records.filter { $0.courseID == selected?.id && !$0.analysisPending && ![.completed, .ignored].contains($0.status) }.count
    }

    var body: some View {
        WorkspaceSplitView(preferredWidth: $listWidth, rules: .courses, label: "Course list width") {
            VStack(spacing: 0) {
                PageHeader(title: "Courses", subtitle: AppLocalization.format("%lld courses", courses.count)) {
                    Button("Add", systemImage: "plus") {
                        protectingEdits(protection) { creating = true; editing = false }
                    }.labelStyle(.iconOnly).help("Add course")
                }.padding(18)
                List(selection: Binding(get: { workspace?.courseID }, set: { id in
                    protectingEdits(protection) {
                        if workspace?.courseID != id { workspace?.courseScrollID = nil }
                        workspace?.courseID = id; creating = false; editing = false
                    }
                })) {
                    ForEach(courses, id: \.id) { course in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(course.courseName).font(.headline).lineLimit(2)
                            if let code = course.courseCode { Text(code).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 6).tag(course.id)
                    }
                }.scrollContentBackground(.hidden)
            }.background(WordNoteTheme.surface)
        } detail: {
            if creating || (editing && selected != nil) {
                VStack(spacing: 0) {
                    HStack {
                        Button("Back to course", systemImage: "chevron.left") {
                            protectingEdits(protection) { creating = false; editing = false }
                        }
                        Spacer()
                    }.padding(.horizontal, 24).padding(.top, 16)
                    CourseEditor(mode: creating ? .create : .edit, course: creating ? nil : selected,
                        termCount: creating ? 0 : termCount, pendingRecordCount: creating ? 0 : pendingCount, errorMessage: $errorMessage,
                        onSaved: { course in workspace?.courseID = course.id; creating = false; editing = false },
                        onDeleted: { workspace?.courseID = nil; editing = false })
                        .id(creating ? "create" : selected?.id.uuidString ?? "missing")
                }
            } else if let selected {
                V3CourseLearningView(course: selected, onEdit: { editing = true }).id(selected.id)
            } else {
                ContentUnavailableView(workspace?.courseID == nil ? "No Course Selected" : "Course No Longer Available", systemImage: "graduationcap")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.onAppear {
            if workspace?.courseID == nil { workspace?.courseID = courses.first?.id }
        }
    }
}

private struct V3CourseLearningView: View {
    @Environment(\.learningWorkspace) private var workspace
    @Environment(\.editProtection) private var protection
    @Environment(\.captureContext) private var captureContext
    @Query private var courses: [CourseModel]
    let course: CourseModel
    let onEdit: () -> Void
    private var cardState: Binding<ReviewCardBrowseState> {
        Binding(get: { workspace?.courseCardState ?? .ready }, set: { workspace?.courseCardState = $0 })
    }
    private var mode: Binding<ReviewMode> {
        Binding(get: { workspace?.courseMode ?? .englishToChinese }, set: { workspace?.courseMode = $0 })
    }
    private var tab: Binding<LearningCourseTab> {
        Binding(get: { workspace?.courseTab ?? .vocabulary }, set: { workspace?.courseTab = $0 })
    }

    var body: some View {
      V3LearningOverviewSurface(courseID: course.id, mode: mode.wrappedValue) { value in
        RememberingScrollView(anchor: Binding(get: { workspace?.courseScrollID }, set: { workspace?.courseScrollID = $0 }),
            ids: [LearningWorkspace.courseHeaderID] + value.terms.map(\.id) + value.cards.map(\.id)
                + value.recentOccurrences.map(\.id) + value.pendingRecords.map(\.id)) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(course.courseName).font(WordNoteTheme.editorialFont(size: 26, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        if let code = course.courseCode { Text(code).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("Edit course", systemImage: "pencil", action: onEdit).labelStyle(.iconOnly).help("Edit course")
                }.rememberListRow(LearningWorkspace.courseHeaderID)
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .leading) { actions }
                }
                Picker("Direction", selection: mode) {
                    ForEach(ReviewMode.allCases) { Text(AppLocalization.text($0.displayTitle)).tag($0) }
                }.frame(maxWidth: 400)
                    V3LearningSummary(statistics: value.statistics)
                    Text("\(value.terms.count) unique terms / \(value.cards.count) cards in this direction")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Picker("Course content", selection: tab) {
                        ForEach(LearningCourseTab.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu).frame(maxWidth: 340)
                    switch tab.wrappedValue {
                    case .vocabulary:
                        termRows(value.terms)
                    case .cards:
                        Picker("State", selection: cardState) {
                            ForEach(ReviewCardBrowseState.allCases) { Text(AppLocalization.text($0.title)).tag($0) }
                        }.frame(maxWidth: 340)
                        LearningCardRows(cards: value.cards.filter { $0.state == cardState.wrappedValue }, open: open)
                    case .weak:
                        termRows(value.terms.filter { value.weakTermIDs.contains($0.id) })
                    case .encounters:
                        if value.recentOccurrences.isEmpty { Text("No captures for this course").foregroundStyle(.secondary) }
                        VStack(spacing: 0) {
                          ForEach(value.recentOccurrences, id: \.id) { occurrence in
                            LearningLinkRow(title: occurrence.rawTextSnapshot,
                                subtitle: occurrence.note, detail: occurrence.occurredAt.formatted(date: .abbreviated, time: .shortened)) {
                                if let id = occurrence.sourceRecordID { open(.record(id)) }
                                else { open(.term(occurrence.termID)) }
                            }.rememberListRow(occurrence.id)
                            Divider()
                          }
                        }
                    case .inbox:
                        if value.pendingRecords.isEmpty { Text("Inbox is clear for this course").foregroundStyle(.secondary) }
                        VStack(spacing: 0) {
                          ForEach(value.pendingRecords) { item in
                            LearningLinkRow(title: item.record.rawText, subtitle: item.previewText, detail: AppLocalization.text(item.statusTitle)) { open(.record(item.id)) }
                                .rememberListRow(item.id)
                            Divider()
                          }
                        }
                    }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
      }.background(WordNoteTheme.canvas)
    }

    @ViewBuilder private var actions: some View {
        Button("Review", systemImage: "play.fill") { open(.review(.init(courseID: course.id, mode: mode.wrappedValue))) }
            .buttonStyle(.borderedProminent)
        Button("Add", systemImage: "plus") {
            workspace?.open(.capture(courseID: course.id), protection: protection) {
                guard let captureContext else { throw CaptureContextError.unavailable }
                guard courses.contains(where: { $0.id == course.id }) else { throw CaptureContextError.missingCourse }
                captureContext.reconcileCourses(Set(courses.map(\.id)))
                try captureContext.selectCourse(course.id)
            }
        }
        Button("Inbox", systemImage: "tray") { open(.inbox(courseID: course.id)) }
    }

    @ViewBuilder private func termRows(_ values: [WordNoteSnapshotPayload.Term]) -> some View {
      VStack(alignment: .leading, spacing: 0) {
        if values.isEmpty { Text("No terms in this view").foregroundStyle(.secondary) }
        ForEach(values, id: \.id) { term in
            LearningLinkRow(title: term.term, subtitle: term.chineseMeaning) { open(.term(term.id)) }
                .rememberListRow(term.id)
            Divider()
        }
      }
    }

    private func open(_ route: LearningRoute) { workspace?.open(route, protection: protection) }
}
#endif
