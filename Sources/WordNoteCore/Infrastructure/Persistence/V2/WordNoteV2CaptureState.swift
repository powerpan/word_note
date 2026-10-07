import Foundation

public extension WordNoteSnapshotV2Payload {
    struct CourseRevision: Codable, Equatable, Sendable {
        public var id: UUID
        public var revision: Int
    }

    struct RecordState: Codable, Equatable, Sendable {
        public var id: UUID
        public var captureID: UUID
        public var lookupIntentRaw: String
        public var resolvedLookupDirectionRaw: String
        public var directionDetectorVersion: String
        public var analysisGeneration: Int
        public var attemptID: UUID?
        public var queueStateRaw: String
        public var autoRetryCount: Int
        public var nextAttemptAt: Date?
        public var revision: Int
    }

    struct CandidateState: Codable, Equatable, Sendable {
        public var id: UUID
        public var revision: Int
        public var savedTermID: UUID?
        public var savedLinkStateRaw: String
        public var confirmationOperationID: UUID?
        public var analysisGeneration: Int
    }

    struct TermState: Codable, Equatable, Sendable {
        public var id: UUID
        public var revision: Int
        public var counterSemanticsVersionRaw: String
    }
}

extension WordNoteSnapshotV2Payload.CourseRevision {
    init(_ model: WordNoteSchemaV2.CourseModel) {
        id = model.id
        revision = model.revision
    }

    func apply(to model: WordNoteSchemaV2.CourseModel) {
        model.revision = revision
    }
}

extension WordNoteSnapshotV2Payload.RecordState {
    init(_ model: WordNoteSchemaV2.InputRecordModel) {
        id = model.id
        captureID = model.captureID
        lookupIntentRaw = model.lookupIntentRaw
        resolvedLookupDirectionRaw = model.resolvedLookupDirectionRaw
        directionDetectorVersion = model.directionDetectorVersion
        analysisGeneration = model.analysisGeneration
        attemptID = model.attemptID
        queueStateRaw = model.queueStateRaw
        autoRetryCount = model.autoRetryCount
        nextAttemptAt = model.nextAttemptAt
        revision = model.revision
    }

    func apply(to model: WordNoteSchemaV2.InputRecordModel) {
        model.captureID = captureID
        model.lookupIntentRaw = lookupIntentRaw
        model.resolvedLookupDirectionRaw = resolvedLookupDirectionRaw
        model.directionDetectorVersion = directionDetectorVersion
        model.analysisGeneration = analysisGeneration
        model.attemptID = attemptID
        model.queueStateRaw = queueStateRaw
        model.autoRetryCount = autoRetryCount
        model.nextAttemptAt = nextAttemptAt
        model.revision = revision
    }
}

extension WordNoteSnapshotV2Payload.CandidateState {
    init(_ model: WordNoteSchemaV2.CandidateTermModel) {
        id = model.id
        revision = model.revision
        savedTermID = model.savedTermID
        savedLinkStateRaw = model.savedLinkStateRaw
        confirmationOperationID = model.confirmationOperationID
        analysisGeneration = model.analysisGeneration
    }

    func apply(to model: WordNoteSchemaV2.CandidateTermModel) {
        model.revision = revision
        model.savedTermID = savedTermID
        model.savedLinkStateRaw = savedLinkStateRaw
        model.confirmationOperationID = confirmationOperationID
        model.analysisGeneration = analysisGeneration
    }
}

extension WordNoteSnapshotV2Payload.TermState {
    init(_ model: WordNoteSchemaV2.TermModel) {
        id = model.id
        revision = model.revision
        counterSemanticsVersionRaw = model.counterSemanticsVersionRaw
    }

    func apply(to model: WordNoteSchemaV2.TermModel) {
        model.revision = revision
        model.counterSemanticsVersionRaw = counterSemanticsVersionRaw
    }
}
