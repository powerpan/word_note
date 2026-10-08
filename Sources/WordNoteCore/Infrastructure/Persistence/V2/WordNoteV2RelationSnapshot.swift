import Foundation

public extension WordNoteSnapshotV2Payload {
    struct Occurrence: Codable, Equatable, Sendable {
        public var id: UUID
        public var termID: UUID
        public var captureID: UUID
        public var sourceRecordID: UUID?
        public var rawTextSnapshot: String
        public var note: String?
        public var courseID: UUID?
        public var sourceTypeRaw: String
        public var occurredAt: Date
        public var capturedViaRaw: String
        public var legacy: Bool
        public var sourceTitle: String?
        public var sourceURL: String?
        public var sourcePage: String?
        public var createdAt: Date
    }

    struct CourseLink: Codable, Equatable, Sendable {
        public var id: UUID
        public var termID: UUID
        public var courseID: UUID
        public var createdAt: Date
    }

    struct LookupEvent: Codable, Equatable, Sendable {
        public var id: UUID
        public var termID: UUID
        public var captureID: UUID
        public var occurrenceID: UUID?
        public var occurredAt: Date
        public var kindRaw: String
        public var createdAt: Date
    }
}

extension WordNoteSnapshotV2Payload.Occurrence {
    public init(_ model: WordNoteSchemaV2.TermOccurrenceModel) {
        id = model.id
        termID = model.termID
        captureID = model.captureID
        sourceRecordID = model.sourceRecordID
        rawTextSnapshot = model.rawTextSnapshot
        note = model.note
        courseID = model.courseID
        sourceTypeRaw = model.sourceTypeRaw
        occurredAt = model.occurredAt
        capturedViaRaw = model.capturedViaRaw
        legacy = model.legacy
        sourceTitle = model.sourceTitle
        sourceURL = model.sourceURL
        sourcePage = model.sourcePage
        createdAt = model.createdAt
    }

    func model() throws -> WordNoteSchemaV2.TermOccurrenceModel {
        WordNoteSchemaV2.TermOccurrenceModel(
            id: id, termID: termID, captureID: captureID, sourceRecordID: sourceRecordID,
            rawTextSnapshot: rawTextSnapshot, note: note, courseID: courseID,
            sourceType: try snapshotEnum(sourceTypeRaw), occurredAt: occurredAt,
            capturedVia: try snapshotEnum(capturedViaRaw), legacy: legacy,
            sourceTitle: sourceTitle, sourceURL: sourceURL, sourcePage: sourcePage, createdAt: createdAt
        )
    }
}

extension WordNoteSnapshotV2Payload.CourseLink {
    public init(_ model: WordNoteSchemaV2.TermCourseLinkModel) {
        id = model.id
        termID = model.termID
        courseID = model.courseID
        createdAt = model.createdAt
    }

    func model() -> WordNoteSchemaV2.TermCourseLinkModel {
        WordNoteSchemaV2.TermCourseLinkModel(id: id, termID: termID, courseID: courseID, createdAt: createdAt)
    }
}

extension WordNoteSnapshotV2Payload.LookupEvent {
    public init(_ model: WordNoteSchemaV2.LookupEventModel) {
        id = model.id
        termID = model.termID
        captureID = model.captureID
        occurrenceID = model.occurrenceID
        occurredAt = model.occurredAt
        kindRaw = model.kindRaw
        createdAt = model.createdAt
    }

    func model() throws -> WordNoteSchemaV2.LookupEventModel {
        WordNoteSchemaV2.LookupEventModel(
            id: id, termID: termID, captureID: captureID, occurrenceID: occurrenceID,
            occurredAt: occurredAt, kind: try snapshotEnum(kindRaw), createdAt: createdAt
        )
    }
}
