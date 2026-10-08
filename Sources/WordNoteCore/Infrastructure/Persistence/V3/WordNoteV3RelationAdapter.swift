import Foundation

extension WordNoteSnapshotV2Payload.Occurrence {
    public init(_ model: WordNoteSchemaV3.TermOccurrenceModel) {
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

    func modelV3() throws -> WordNoteSchemaV3.TermOccurrenceModel {
        WordNoteSchemaV3.TermOccurrenceModel(
            id: id, termID: termID, captureID: captureID, sourceRecordID: sourceRecordID,
            rawTextSnapshot: rawTextSnapshot, note: note, courseID: courseID,
            sourceType: try snapshotEnum(sourceTypeRaw), occurredAt: occurredAt,
            capturedVia: try snapshotEnum(capturedViaRaw), legacy: legacy,
            sourceTitle: sourceTitle, sourceURL: sourceURL, sourcePage: sourcePage, createdAt: createdAt
        )
    }
}

extension WordNoteSnapshotV2Payload.CourseLink {
    public init(_ model: WordNoteSchemaV3.TermCourseLinkModel) {
        id = model.id
        termID = model.termID
        courseID = model.courseID
        createdAt = model.createdAt
    }

    func modelV3() -> WordNoteSchemaV3.TermCourseLinkModel {
        WordNoteSchemaV3.TermCourseLinkModel(id: id, termID: termID, courseID: courseID, createdAt: createdAt)
    }
}

extension WordNoteSnapshotV2Payload.LookupEvent {
    public init(_ model: WordNoteSchemaV3.LookupEventModel) {
        id = model.id
        termID = model.termID
        captureID = model.captureID
        occurrenceID = model.occurrenceID
        occurredAt = model.occurredAt
        kindRaw = model.kindRaw
        createdAt = model.createdAt
    }

    func modelV3() throws -> WordNoteSchemaV3.LookupEventModel {
        WordNoteSchemaV3.LookupEventModel(
            id: id, termID: termID, captureID: captureID, occurrenceID: occurrenceID,
            occurredAt: occurredAt, kind: try snapshotEnum(kindRaw), createdAt: createdAt
        )
    }
}
