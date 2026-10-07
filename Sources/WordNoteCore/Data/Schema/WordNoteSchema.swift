import SwiftData

/// Historical storage shape. Add fields only in a new schema, never in V1.
public enum WordNoteSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static let models: [any PersistentModel.Type] = [
        CourseModel.self,
        InputRecordModel.self,
        CandidateTermModel.self,
        TermModel.self,
        ReviewEventModel.self
    ]
}

public enum WordNoteMigrationPlan: SchemaMigrationPlan {
    public static let schemas: [any VersionedSchema.Type] = [
        WordNoteSchemaV1.self
    ]

    public static let stages: [MigrationStage] = []
}
