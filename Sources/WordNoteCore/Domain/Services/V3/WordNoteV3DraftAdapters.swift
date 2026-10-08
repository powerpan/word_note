import Foundation

// Draft and confirmation values are shared; only their model-bound readers/writers differ.
extension WordNoteV2CandidateEdit {
    @MainActor
    public init(_ candidate: WordNoteSchemaV3.CandidateTermModel, recordRevision: Int) {
        id = candidate.id
        revision = candidate.revision
        self.recordRevision = recordRevision
        term = candidate.term
        importance = candidate.importance
        category = candidate.category
        chineseMeaning = candidate.chineseMeaning ?? ""
        englishDefinition = candidate.englishDefinition ?? ""
        aiContextExplanation = candidate.aiContextExplanation ?? ""
        exampleSentence = candidate.exampleSentence ?? ""
    }
}

extension WordNoteManualSourceValues {
    @MainActor
    public init(_ record: WordNoteSchemaV3.InputRecordModel) {
        id = record.id
        rawText = record.rawText
        note = record.note ?? ""
        courseID = record.courseID
        source = record.sourceTypeRaw
        direction = record.resolvedLookupDirectionRaw
        status = record.statusRaw
        queueState = record.queueStateRaw
        generation = record.analysisGeneration
    }
}
