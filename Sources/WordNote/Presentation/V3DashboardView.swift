#if WORDNOTE_V3_VALIDATION
import SwiftUI
import WordNoteCore

struct DashboardView: View {
    @Environment(\.learningWorkspace) private var workspace
    @Environment(\.editProtection) private var protection
    @State private var localMode = ReviewMode.englishToChinese
    @State private var localCardState = ReviewCardBrowseState.ready
    let onOpenReview: () -> Void
    let onOpenInbox: () -> Void
    private var mode: Binding<ReviewMode> {
        Binding(get: { workspace?.dashboardMode ?? localMode }, set: {
            if let workspace { workspace.dashboardMode = $0 } else { localMode = $0 }
        })
    }
    private var cardState: Binding<ReviewCardBrowseState> {
        Binding(get: { workspace?.dashboardCardState ?? localCardState }, set: {
            if let workspace { workspace.dashboardCardState = $0 } else { localCardState = $0 }
        })
    }

    var body: some View {
      V3LearningOverviewSurface(courseID: nil, mode: mode.wrappedValue) { value in
        RememberingScrollView(anchor: Binding(get: { workspace?.dashboardScrollID }, set: { workspace?.dashboardScrollID = $0 }),
            ids: [LearningWorkspace.dashboardHeaderID] + value.cards.map(\.id) + value.pendingRecords.map(\.id) + value.courses.map(\.id)) {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Today").font(WordNoteTheme.editorialFont(size: 30, weight: .semibold))
                    Spacer()
                    Picker("Direction", selection: mode) {
                        ForEach(ReviewMode.allCases) { Text(AppLocalization.text($0.displayTitle)).tag($0) }
                    }.fixedSize()
                }.rememberListRow(LearningWorkspace.dashboardHeaderID)
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(value.resumableSession == nil ? "Review" : "Current group").font(.title2.weight(.semibold))
                            if let active = value.resumableSession {
                                Text("\(active.session.scope.courseName ?? AppLocalization.text("All courses")) / \(AppLocalization.text(active.session.scope.mode.displayTitle))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Text("\(active.items.count) cards").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(value.resumableSession == nil ? "Start Review" : "Continue Review", systemImage: "play.fill") {
                            if workspace == nil { onOpenReview() }
                            else if value.resumableSession != nil { open(.continueReview) }
                            else { open(.review(.init(mode: mode.wrappedValue))) }
                        }.buttonStyle(.borderedProminent)
                    }
                    V3LearningSummary(statistics: value.statistics)
                    Divider()
                    Picker("Cards", selection: cardState) {
                        Text("Ready (\(value.statistics.workload.readyCards))").tag(ReviewCardBrowseState.ready)
                        Text("New (\(value.statistics.workload.newCards))").tag(ReviewCardBrowseState.new)
                        Text("Waiting (\(value.statistics.workload.waitingRelearningCards))").tag(ReviewCardBrowseState.waiting)
                    }.pickerStyle(.segmented)
                    LearningCardRows(cards: Array(value.cards.filter { $0.state == cardState.wrappedValue }.prefix(5)), open: open)
                    if value.cards.filter({ $0.state == cardState.wrappedValue }).count > 5 {
                        Button("View All Cards", systemImage: "books.vertical") {
                            open(.vocabulary(courseID: nil, cards: .init(mode: mode.wrappedValue, state: cardState.wrappedValue)))
                        }
                    }
                    Divider()
                    HStack {
                        Text("Inbox").font(.title2.weight(.semibold))
                        Text(String(value.pendingRecords.count)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Inbox", systemImage: "tray") {
                            if workspace == nil { onOpenInbox() } else { open(.inbox(courseID: nil)) }
                        }
                    }
                    VStack(spacing: 0) {
                        ForEach(value.pendingRecords.prefix(5)) { item in
                            LearningLinkRow(title: item.record.rawText, subtitle: item.previewText, detail: AppLocalization.text(item.statusTitle)) { open(.record(item.id)) }
                                .rememberListRow(item.id)
                        }
                    }
                    if value.pendingRecords.isEmpty { Text("Inbox is clear").foregroundStyle(.secondary) }
                    Divider()
                    HStack {
                        Text("Courses").font(.headline)
                        Spacer()
                        Text("\(value.terms.count) unique terms").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 0) {
                        ForEach(value.courses.sorted { $0.courseName < $1.courseName }, id: \.id) { course in
                            LearningLinkRow(title: course.courseName, subtitle: course.courseCode) { open(.course(course.id)) }
                                .rememberListRow(course.id)
                        }
                    }
                    if value.courses.isEmpty { Text("No courses").foregroundStyle(.secondary) }
            }.padding(28).frame(maxWidth: 1040, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
      }.background(WordNoteTheme.canvas)
    }

    private func open(_ route: LearningRoute) { workspace?.open(route, protection: protection) }
}
#endif
