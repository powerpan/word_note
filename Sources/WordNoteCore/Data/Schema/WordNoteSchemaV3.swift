import SwiftData

/// Isolated card-based schema; activation also requires the B04 scheduler and write-path gates.
public enum WordNoteSchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 0, 0)

    public static let models: [any PersistentModel.Type] = [
        CourseModel.self, InputRecordModel.self, CandidateTermModel.self, TermModel.self,
        ReviewEventModel.self, TermOccurrenceModel.self, TermCourseLinkModel.self, LookupEventModel.self,
        ReviewCardModel.self, ReviewSessionModel.self, ReviewSessionItemModel.self
    ]
}
