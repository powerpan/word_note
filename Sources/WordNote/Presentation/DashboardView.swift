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
        let endOfToday = Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 60 * 60)
        return terms.filter { term in
            guard let nextReviewAt = term.nextReviewAt else { return false }
            return nextReviewAt < endOfToday
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Dashboard")
                .font(.largeTitle.bold())

            HStack(spacing: 12) {
                MetricTile(title: "Pending Records", value: pendingRecordCount)
                MetricTile(title: "Vocabulary", value: terms.count)
                MetricTile(title: "Due Today", value: dueTodayCount)
                MetricTile(title: "Courses", value: courses.count)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Project Foundation")
                    .font(.headline)
                Text("The M1 shell is ready for the Quick Add, AI analysis, candidate review, vocabulary, course, and review flows planned in the engineering docs.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(28)
    }
}

private struct MetricTile: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(.title.bold())
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
