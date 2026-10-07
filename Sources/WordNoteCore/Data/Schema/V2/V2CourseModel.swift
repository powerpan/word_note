import Foundation
import SwiftData

extension WordNoteSchemaV2 {
    @Model
    public final class CourseModel {
        @Attribute(.unique) public var id: UUID
        public var revision: Int = 0
        public var courseName: String
        public var courseCode: String?
        public var instructor: String?
        public var semester: String?
        public var courseDescription: String?
        public var createdAt: Date
        public var updatedAt: Date

        public init(
            id: UUID = UUID(),
            courseName: String,
            courseCode: String? = nil,
            instructor: String? = nil,
            semester: String? = nil,
            courseDescription: String? = nil,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.courseName = courseName
            self.courseCode = courseCode
            self.instructor = instructor
            self.semester = semester
            self.courseDescription = courseDescription
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }
}
