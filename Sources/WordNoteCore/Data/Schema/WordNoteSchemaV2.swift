import SwiftData

/// Isolated migration target until the A01/A02 application activation gates pass.
public enum WordNoteSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)

    public static let models: [any PersistentModel.Type] = [
        CourseModel.self, InputRecordModel.self, CandidateTermModel.self,
        TermModel.self, ReviewEventModel.self, TermOccurrenceModel.self,
        TermCourseLinkModel.self, LookupEventModel.self
    ]
}
