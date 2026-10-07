import SwiftData
import SwiftUI
import WordNoteCore

struct DashboardView: View {
    @Query private var inputRecords: [InputRecordModel]
    @Query private var terms: [TermModel]
    @Query private var courses: [CourseModel]

    let onOpenReview: () -> Void
    let onOpenInbox: () -> Void

    private var pendingRecordCount: Int {
        pendingRecords.count
    }

    private var dueTodayCount: Int {
        dueTerms.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DashboardBriefing(dueTodayCount: dueTodayCount)
                    .padding(.bottom, 24)

                DashboardMetricLedger(metrics: metrics)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        DashboardReviewLedger(
                            terms: duePreview,
                            totalCount: dueTodayCount,
                            onOpenReview: onOpenReview
                        )
                        .frame(minWidth: 450, maxWidth: .infinity, alignment: .topLeading)

                        Rectangle()
                            .fill(WordNoteTheme.line)
                            .frame(width: 1)
                            .padding(.horizontal, 18)

                        DashboardInboxLedger(
                            records: Array(pendingRecords.prefix(5)),
                            onOpenInbox: onOpenInbox
                        )
                        .frame(minWidth: 280, maxWidth: 390, alignment: .topLeading)
                    }

                    VStack(spacing: 26) {
                        DashboardReviewLedger(
                            terms: duePreview,
                            totalCount: dueTodayCount,
                            onOpenReview: onOpenReview
                        )
                        Divider()
                        DashboardInboxLedger(
                            records: Array(pendingRecords.prefix(5)),
                            onOpenInbox: onOpenInbox
                        )
                    }
                }
                .padding(.top, 30)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
            .frame(maxWidth: 1480, alignment: .topLeading)
        }
        .background(WordNoteTheme.canvas)
    }

    private var metrics: [DashboardMetric] {
        [
            DashboardMetric(title: "Pending Records", value: pendingRecordCount, systemImage: "tray", tint: WordNoteTheme.brand),
            DashboardMetric(title: "Vocabulary", value: terms.count, systemImage: "books.vertical", tint: WordNoteTheme.teal),
            DashboardMetric(title: "Due Today", value: dueTodayCount, systemImage: "calendar", tint: WordNoteTheme.brand),
            DashboardMetric(title: "Courses", value: courses.count, systemImage: "graduationcap", tint: WordNoteTheme.teal)
        ]
    }

    private var pendingRecords: [InputRecordModel] {
        inputRecords
            .filter { !$0.analysisPending && [.draft, .analyzed, .failed].contains($0.status) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var duePreview: [TermModel] {
        Array(dueTerms.prefix(5))
    }

    private var dueTerms: [TermModel] {
        ReviewQueuePolicy().terms(from: terms)
    }
}

private struct DashboardBriefing: View {
    let dueTodayCount: Int

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 28) {
                dateBlock
                Rectangle()
                    .fill(WordNoteTheme.strongLine)
                    .frame(width: 1, height: 64)
                summaryBlock
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 12) {
                dateBlock
                summaryBlock
            }
        }
    }

    private var dateBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DAILY BRIEFING")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WordNoteTheme.teal)
            Text(
                Date.now.formatted(
                    .dateTime
                        .weekday(.wide)
                        .month(.wide)
                        .day()
                        .year()
                        .locale(Locale(identifier: "en_US"))
                )
            )
                .font(WordNoteTheme.editorialFont(size: 23, weight: .medium))
        }
        .frame(minWidth: 270, alignment: .leading)
    }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(summaryTitle)
                .font(WordNoteTheme.editorialFont(size: 15, weight: .medium))
            Text(summaryDetail)
                .font(.system(size: 12))
                .foregroundStyle(WordNoteTheme.mutedInk)
        }
    }

    private var summaryTitle: String {
        dueTodayCount == 0
            ? "Your review queue is clear for today."
            : "You have \(dueTodayCount) item\(dueTodayCount == 1 ? "" : "s") due for review today."
    }

    private var summaryDetail: String {
        dueTodayCount == 0
            ? "Capture useful language as it appears in class and research."
            : "Keep the rhythm. Consistent review builds mastery."
    }
}

private struct DashboardMetric: Identifiable {
    let title: String
    let value: Int
    let systemImage: String
    let tint: Color

    var id: String { title }
}

private struct DashboardMetricLedger: View {
    let metrics: [DashboardMetric]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                    DashboardMetricCell(metric: metric)
                    if index < metrics.count - 1 {
                        Rectangle()
                            .fill(WordNoteTheme.line)
                            .frame(width: 1, height: 54)
                    }
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 2), spacing: 0) {
                ForEach(metrics) { metric in
                    DashboardMetricCell(metric: metric)
                }
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(WordNoteTheme.line).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(WordNoteTheme.line).frame(height: 1)
        }
    }
}

private struct DashboardMetricCell: View {
    let metric: DashboardMetric

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: metric.systemImage)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(metric.tint)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(metric.value, format: .number)
                    .font(WordNoteTheme.editorialFont(size: 27, weight: .semibold))
                    .monospacedDigit()
                Text(metric.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WordNoteTheme.mutedInk)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }
}

private struct DashboardReviewLedger: View {
    let terms: [TermModel]
    let totalCount: Int
    let onOpenReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardLedgerHeader(title: "Today", subtitle: "Review Queue", actionTitle: "Open Review", action: onOpenReview)

            if terms.isEmpty {
                DashboardEmptyRow(
                    systemImage: "checkmark.circle",
                    title: "Review queue clear",
                    message: "No saved term is due before the end of today."
                )
                .padding(.top, 22)
            } else {
                reviewColumnHeader
                    .padding(.top, 22)

                ForEach(Array(terms.enumerated()), id: \.element.id) { index, term in
                    DashboardTermLedgerRow(index: index + 1, term: term)
                }

                if totalCount > terms.count {
                    HStack(spacing: 8) {
                        Text("…")
                            .font(WordNoteTheme.editorialFont(size: 17))
                        Text("+ \(totalCount - terms.count) more items")
                            .font(.system(size: 12))
                            .foregroundStyle(WordNoteTheme.mutedInk)
                    }
                    .padding(.vertical, 14)
                }
            }
        }
    }

    private var reviewColumnHeader: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: 22, alignment: .leading)
            Text("TERM").frame(width: 128, alignment: .leading)
            Text("DEFINITION (PREVIEW)").frame(maxWidth: .infinity, alignment: .leading)
            Text("PRIORITY").frame(width: 76, alignment: .leading)
            Text("MASTERY").frame(width: 88, alignment: .leading)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(WordNoteTheme.mutedInk)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WordNoteTheme.strongLine).frame(height: 1)
        }
    }
}

private struct DashboardTermLedgerRow: View {
    let index: Int
    let term: TermModel

    var body: some View {
        HStack(spacing: 12) {
            Text(index, format: .number)
                .font(.caption)
                .foregroundStyle(WordNoteTheme.mutedInk)
                .frame(width: 22, alignment: .leading)

            Text(term.term)
                .font(WordNoteTheme.editorialFont(size: 15, weight: .medium))
                .foregroundStyle(WordNoteTheme.brand)
                .lineLimit(1)
                .frame(width: 128, alignment: .leading)

            Text(term.chineseMeaning ?? term.englishDefinition ?? term.masteryLevel.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            TagChip(title: term.importance.displayTitle, tint: importanceTint)
                .frame(width: 76, alignment: .leading)

            ProgressView(value: masteryProgress)
                .progressViewStyle(.linear)
                .tint(WordNoteTheme.brand)
                .frame(width: 88)
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WordNoteTheme.line).frame(height: 1)
        }
    }

    private var masteryProgress: Double {
        switch term.masteryLevel {
        case .new: 0.12
        case .vague: 0.34
        case .familiar: 0.68
        case .mastered: 1
        }
    }

    private var importanceTint: Color {
        switch term.importance {
        case .low: WordNoteTheme.teal
        case .medium: WordNoteTheme.amber
        case .high: WordNoteTheme.brand
        }
    }
}

private struct DashboardInboxLedger: View {
    let records: [InputRecordModel]
    let onOpenInbox: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardLedgerHeader(title: "Inbox", subtitle: "Recent Activity", actionTitle: "View all", action: onOpenInbox)

            if records.isEmpty {
                DashboardEmptyRow(
                    systemImage: "tray",
                    title: "Nothing pending",
                    message: "Quick Add records and analysis failures will appear here."
                )
                .padding(.top, 22)
            } else {
                ForEach(records, id: \.id) { record in
                    DashboardRecordLedgerRow(record: record)
                }
                .padding(.top, 12)
            }
        }
    }
}

private struct DashboardLedgerHeader: View {
    let title: String
    let subtitle: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(title)
                .font(WordNoteTheme.editorialFont(size: 21, weight: .semibold))
            Text(subtitle.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(WordNoteTheme.mutedInk)
            Spacer()
            Button(action: action) {
                HStack(spacing: 4) {
                    Text(actionTitle)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(WordNoteTheme.teal)
        }
    }
}

private struct DashboardRecordLedgerRow: View {
    let record: InputRecordModel

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: record.analysisFailed ? "exclamationmark.triangle" : "doc.text")
                .foregroundStyle(record.analysisFailed ? WordNoteTheme.amber : WordNoteTheme.teal)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.rawText)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(WordNoteTheme.mutedInk)
            }

            Spacer(minLength: 8)
            TagChip(
                title: record.visibleStatusTitle,
                tint: record.analysisFailed ? WordNoteTheme.amber : WordNoteTheme.teal
            )
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WordNoteTheme.line).frame(height: 1)
        }
    }
}

private struct DashboardEmptyRow: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(WordNoteTheme.teal)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(WordNoteTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
