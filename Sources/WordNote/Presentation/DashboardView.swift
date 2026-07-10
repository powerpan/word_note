import SwiftData
import SwiftUI
import WordNoteCore

struct DashboardView: View {
    @Query private var inputRecords: [InputRecordModel]
    @Query private var terms: [TermModel]
    @Query private var courses: [CourseModel]

    private var pendingRecordCount: Int {
        inputRecords.filter { [.draft, .analyzed, .failed].contains($0.status) }.count
    }

    private var dueTodayCount: Int {
        dueTerms.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    title: "Learning Workspace",
                    subtitle: "Capture technical English, review AI candidates, and keep course vocabulary moving."
                ) {
                    EmptyView()
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    MetricCard(title: "Pending Records", value: pendingRecordCount, systemImage: "tray", tint: .orange)
                    MetricCard(title: "Vocabulary", value: terms.count, systemImage: "books.vertical", tint: .blue)
                    MetricCard(title: "Due Today", value: dueTodayCount, systemImage: "calendar.badge.clock", tint: .purple)
                    MetricCard(title: "Courses", value: courses.count, systemImage: "graduationcap", tint: .green)
                }

                HStack(alignment: .top, spacing: 18) {
                    DashboardSection(title: "Today") {
                        if dueTodayCount == 0 {
                            CompactEmptyState(
                                systemImage: "checkmark.circle",
                                title: "Review queue clear",
                                message: "No saved term is due before the end of today."
                            )
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(duePreview, id: \.id) { term in
                                    DashboardTermRow(term: term)
                                }
                            }
                        }
                    }

                    DashboardSection(title: "Inbox") {
                        if pendingRecords.isEmpty {
                            CompactEmptyState(
                                systemImage: "tray",
                                title: "Nothing pending",
                                message: "Quick Add records and AI analysis failures will appear here."
                            )
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(pendingRecords.prefix(5), id: \.id) { record in
                                    DashboardRecordRow(record: record)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
    }

    private var pendingRecords: [InputRecordModel] {
        inputRecords
            .filter { [.draft, .analyzed, .failed].contains($0.status) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var duePreview: [TermModel] {
        dueTerms
            .prefix(5)
            .map { $0 }
    }

    private var dueTerms: [TermModel] {
        ReviewQueuePolicy().terms(from: terms)
    }
}

private struct DashboardSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct CompactEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DashboardTermRow: View {
    let term: TermModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.closed")
                .foregroundStyle(.purple)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(term.term)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(term.chineseMeaning ?? term.masteryLevel.displayTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            TagChip(title: term.importance.displayTitle, tint: .purple)
        }
    }
}

private struct DashboardRecordRow: View {
    let record: InputRecordModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.status == .failed ? "exclamationmark.triangle" : "doc.text")
                .foregroundStyle(record.status == .failed ? .orange : .blue)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.rawText)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TagChip(title: record.status.displayTitle, tint: record.status == .failed ? .orange : .blue)
        }
    }
}
