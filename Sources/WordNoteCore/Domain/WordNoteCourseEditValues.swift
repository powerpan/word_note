public struct WordNoteCourseEditValues: Equatable, Sendable {
    public var courseName: String
    public var courseCode: String
    public var instructor: String
    public var semester: String
    public var description: String

    public init(courseName: String = "", courseCode: String = "", instructor: String = "", semester: String = "", description: String = "") {
        self.courseName = courseName; self.courseCode = courseCode; self.instructor = instructor
        self.semester = semester; self.description = description
    }

    public var preview: String { [courseName, courseCode, instructor, semester, description].filter { !$0.isEmpty }.joined(separator: "\n") }

    public static var comparisonFields: [WordNoteEditField<Self>] {
        [
            .init("name", title: "Name", keyPath: \.courseName, display: { $0 }),
            .init("code", title: "Code", keyPath: \.courseCode, display: { $0 }),
            .init("instructor", title: "Instructor", keyPath: \.instructor, display: { $0 }),
            .init("semester", title: "Semester", keyPath: \.semester, display: { $0 }),
            .init("description", title: "Description", keyPath: \.description, display: { $0 })
        ]
    }
}
