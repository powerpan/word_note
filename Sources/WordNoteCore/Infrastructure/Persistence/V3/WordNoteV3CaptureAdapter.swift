import Foundation

extension WordNoteSnapshotV2Payload.CourseRevision {
    init(_ model: WordNoteSchemaV3.CourseModel) {
        id = model.id
        revision = model.revision
    }

    func apply(to model: WordNoteSchemaV3.CourseModel) {
        model.revision = revision
    }
}

extension WordNoteSnapshotV2Payload.RecordState {
    init(_ model: WordNoteSchemaV3.InputRecordModel) {
        id = model.id
        captureID = model.captureID
        capturedViaRaw = model.capturedViaRaw
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

    func apply(to model: WordNoteSchemaV3.InputRecordModel) {
        model.captureID = captureID
        model.capturedViaRaw = capturedViaRaw
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
    init(_ model: WordNoteSchemaV3.CandidateTermModel) {
        id = model.id
        revision = model.revision
        savedTermID = model.savedTermID
        savedLinkStateRaw = model.savedLinkStateRaw
        confirmationOperationID = model.confirmationOperationID
        analysisGeneration = model.analysisGeneration
    }

    func apply(to model: WordNoteSchemaV3.CandidateTermModel) {
        model.revision = revision
        model.savedTermID = savedTermID
        model.savedLinkStateRaw = savedLinkStateRaw
        model.confirmationOperationID = confirmationOperationID
        model.analysisGeneration = analysisGeneration
    }
}

extension WordNoteSnapshotV2Payload.TermState {
    init(_ model: WordNoteSchemaV3.TermModel) {
        id = model.id
        revision = model.revision
        counterSemanticsVersionRaw = model.counterSemanticsVersionRaw
    }

    func apply(to model: WordNoteSchemaV3.TermModel) {
        model.revision = revision
        model.counterSemanticsVersionRaw = counterSemanticsVersionRaw
    }
}
