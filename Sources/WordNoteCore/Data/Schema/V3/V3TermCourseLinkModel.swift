import Foundation
import SwiftData

extension WordNoteSchemaV3 {
    @Model
    public final class TermCourseLinkModel {
        @Attribute(.unique) public var id: UUID
        public var termID: UUID
        public var courseID: UUID
        public var createdAt: Date

        public init(id: UUID = UUID(), termID: UUID, courseID: UUID, createdAt: Date = Date()) {
            self.id = id
            self.termID = termID
            self.courseID = courseID
            self.createdAt = createdAt
        }
    }
}
