import SwiftData
import SwiftUI
import WordNoteCore

struct CoursesOverviewView: View {
    @Environment(\.editProtection) private var editProtection
    private var memberships = AppCourseMemberships()
    @Query private var storedCourses: [CourseModel]
    @Query private var terms: [TermModel]
    @Query private var records: [InputRecordModel]

    @State private var selectedCourseID: UUID?
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var courses: [CourseModel] {
        storedCourses.sorted { $0.courseName.localizedStandardCompare($1.courseName) == .orderedAscending }
    }

    private var selectedCourse: CourseModel? {
        guard let selectedCourseID else { return courses.first }
        return courses.first { $0.id == selectedCourseID }
    }

    var body: some View {
        GeometryReader { proxy in
            let listWidth = CoursesLayoutMetrics.listWidth(for: proxy.size.width)

            HStack(spacing: 0) {
                VStack(spacing: 12) {
                PageHeader(
                    title: "Courses",
                    subtitle: "\(courses.count) course\(courses.count == 1 ? "" : "s")"
                ) {
                    Button {
                        protectingEdits(editProtection) {
                            isCreating = true
                            selectedCourseID = nil
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
                .padding([.horizontal, .top], 18)

                List(selection: Binding(get: { selectedCourseID }, set: { id in
                    guard selectedCourseID != id || isCreating else { return }
                    protectingEdits(editProtection) { selectedCourseID = id; isCreating = false }
                })) {
                    ForEach(courses, id: \.id) { course in
                        CourseRow(
                            course: course,
                            termCount: termCount(for: course.id),
                            pendingRecordCount: pendingRecordCount(for: course.id)
                        )
                        .tag(course.id)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(WordNoteTheme.surface)
                .overlay {
                    if courses.isEmpty {
                        ContentUnavailableView(
                            "No Courses",
                            systemImage: "graduationcap",
                            description: Text("Add courses to organize records and reviews.")
                        )
                        .allowsHitTesting(false)
                    }
                }
            }
                .frame(width: listWidth)
                .background(WordNoteTheme.surface)

                Divider()

                if isCreating {
                    CourseEditor(
                    mode: .create,
                    course: nil,
                    termCount: 0,
                    pendingRecordCount: 0,
                    errorMessage: $errorMessage,
                    onSaved: { course in
                        selectedCourseID = course.id
                        isCreating = false
                    },
                    onDeleted: {}
                    )
                    .id("new-course")
                } else if let selectedCourse {
                    CourseEditor(
                    mode: .edit,
                    course: selectedCourse,
                    termCount: termCount(for: selectedCourse.id),
                    pendingRecordCount: pendingRecordCount(for: selectedCourse.id),
                    errorMessage: $errorMessage,
                    onSaved: { course in
                        selectedCourseID = course.id
                    },
                    onDeleted: {
                        selectedCourseID = courses.first?.id
                    }
                    )
                    .id(selectedCourse.id)
                } else {
                    ContentUnavailableView("No Course Selected", systemImage: "graduationcap")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: CoursesLayoutMetrics.minContentWidth, minHeight: 620)
        .onAppear(perform: maintainSelection)
        .onChange(of: courses.map(\.id)) {
            maintainSelection()
        }
    }

    private func termCount(for courseID: UUID) -> Int {
        terms.filter { memberships.matches($0, courseID: courseID) }.count
    }

    private func pendingRecordCount(for courseID: UUID) -> Int {
        records.filter { record in
            record.courseID == courseID && !record.analysisPending && [.draft, .analyzed, .failed].contains(record.status)
        }.count
    }

    private func maintainSelection() {
        guard !isCreating else { return }
        if let selectedCourseID, courses.contains(where: { $0.id == selectedCourseID }) {
            return
        }
        selectedCourseID = courses.first?.id
    }
}

private enum CoursesLayoutMetrics {
    static let minContentWidth: CGFloat = 860
    static let minListWidth: CGFloat = 320
    static let maxListWidth: CGFloat = 380

    static func listWidth(for contentWidth: CGFloat) -> CGFloat {
        min(max(contentWidth * 0.36, minListWidth), maxListWidth)
    }
}

private struct CourseRow: View {
    let course: CourseModel
    let termCount: Int
    let pendingRecordCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(course.courseName)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                if let courseCode = course.courseCode {
                    Text(courseCode)
                }
                Text("\(termCount) terms")
                Text("\(pendingRecordCount) pending")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private enum CourseEditorMode {
    case create
    case edit
}

private struct CourseEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.savedChangeHistory) private var undoHistory

    let mode: CourseEditorMode
    let course: CourseModel?
    let termCount: Int
    let pendingRecordCount: Int
    @Binding var errorMessage: String?
    let onSaved: (CourseModel) -> Void
    let onDeleted: () -> Void

    @State private var values = WordNoteEditDraft(CourseEditorValues())
    @State private var draftID = UUID()
    private var draft: CourseEditorValues { get { values.value } nonmutating set { values.value = newValue } }
    private var original: CourseEditorValues { get { values.baseline } nonmutating set { values.baseline = newValue } }
    private var editRevision: Int { get { values.revision } nonmutating set { values.revision = newValue } }
    @State private var statusMessage: String?
    @State private var isDeleteConfirmationPresented = false

    private var isDirty: Bool { draft != original }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(mode == .create ? "New Course" : "Course Detail")
                        .font(WordNoteTheme.editorialFont(size: 25, weight: .semibold))
                    Spacer()
                    Button("Save") {
                        save()
                    }
                    if mode == .edit {
                        Button("Delete", role: .destructive) {
                            isDeleteConfirmationPresented = true
                        }
                        .confirmationDialog(
                            "Delete this course?",
                            isPresented: $isDeleteConfirmationPresented
                        ) {
                            Button("Delete Course", role: .destructive, action: delete)
                        } message: {
                            Text("Courses referenced by terms or input records cannot be deleted.")
                        }
                    }
                }

                if let statusMessage {
                    StatusBanner(message: statusMessage, kind: .success)
                }

                if let errorMessage {
                    StatusBanner(message: errorMessage, kind: .warning)
                }
                if isDirty {
                    if let course, editRevision != course.editRevision {
                        StatusBanner(message: "This course changed in another operation. Your draft has not been overwritten.", kind: .warning)
                    }
                    Button("Discard Changes", action: load)
                }

                if mode == .edit {
                    HStack(spacing: 12) {
                        CourseMetric(title: "Terms", value: termCount)
                        CourseMetric(title: "Pending Records", value: pendingRecordCount)
                    }
                }

                GroupBox("Course") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        formRow("Name") {
                            TextField("Course name", text: $values.value.courseName)
                        }
                        formRow("Code") {
                            TextField("Course code", text: $values.value.courseCode)
                        }
                        formRow("Instructor") {
                            TextField("Instructor", text: $values.value.instructor)
                        }
                        formRow("Semester") {
                            TextField("Semester", text: $values.value.semester)
                        }
                        formRow("Description") {
                            TextField("Description", text: $values.value.description, axis: .vertical)
                                .lineLimit(2...6)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(28)
        }
        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        .groupBoxStyle(WordNoteGroupBoxStyle())
        .onAppear(perform: load)
        .onChange(of: course?.id) {
            load()
        }
        .onChange(of: course?.editRevision) { if !isDirty { load() } }
        .protectEdits(id: draftID, value: draft, isDirty: { values.isDirty }, title: "Course: \(original.courseName.isEmpty ? "New Course" : original.courseName)",
                      preview: { values.value.preview }, save: capturedSave, discard: discardDraft)
    }

    @ViewBuilder
    private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func load() {
        editRevision = course?.editRevision ?? 0
        draft = CourseEditorValues(courseName: course?.courseName ?? "", courseCode: course?.courseCode ?? "",
                                   instructor: course?.instructor ?? "", semester: course?.semester ?? "",
                                   description: course?.courseDescription ?? "")
        original = draft
        statusMessage = nil
        errorMessage = nil
    }

    private func save() {
        do {
            try capturedSave()
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private var capturedSave: () throws -> Void {
        let id = course?.id
        return {
            let value = values.value
            let revision = values.revision
            let service = CourseService(modelContext: modelContext, expectedRevision: revision, undoHistory: undoHistory)
            let savedCourse: CourseModel
            if let id {
                guard let course = try modelContext.fetch(FetchDescriptor<CourseModel>()).first(where: { $0.id == id }) else {
                    throw WordNoteV2ContentError.missingEntity
                }
                try service.update(
                    course,
                    courseName: value.courseName,
                    courseCode: value.courseCode,
                    instructor: value.instructor,
                    semester: value.semester,
                    description: value.description
                )
                savedCourse = course
            } else {
                savedCourse = try service.create(
                    courseName: value.courseName,
                    courseCode: value.courseCode,
                    instructor: value.instructor,
                    semester: value.semester,
                    description: value.description
                )
            }
            editRevision = savedCourse.editRevision
            original = value
            statusMessage = "Saved."
            errorMessage = nil
            onSaved(savedCourse)
        }
    }

    private func discardDraft() {
        draft = original
        errorMessage = nil
    }

    private func delete() {
        guard let course else { return }
        let service = CourseService(modelContext: modelContext, expectedRevision: editRevision)

        do {
            try service.delete(course)
            discardDraft()
            statusMessage = nil
            errorMessage = nil
            onDeleted()
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct CourseEditorValues: Equatable {
    var courseName = ""
    var courseCode = ""
    var instructor = ""
    var semester = ""
    var description = ""
    var preview: String { [courseName, courseCode, instructor, semester, description].filter { !$0.isEmpty }.joined(separator: "\n") }
}

private struct CourseMetric: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(.title2.bold())
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .wordNoteSurface()
    }
}
