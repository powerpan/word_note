import Foundation

public enum WordNoteV2ConfirmationTarget: Equatable, Sendable {
    case createNew
    case linkExisting(termID: UUID, expectedRevision: Int)
}

extension WordNoteV2ContentService {
    public func createManualTerm(
        sourceRecordID: UUID, expectedRecordRevision: Int, termText: String,
        chineseMeaning: String?, englishDefinition: String?, at date: Date = Date()
    ) throws -> WordNoteV2VersionedID {
        try transaction {
            try validateDate(date)
            let source = try record(sourceRecordID)
            try requireRevision(source.revision, expectedRecordRevision)
            try requireEditableCuration(source)
            let text = termText.trimmingCharacters(in: .whitespacesAndNewlines)
            try validateSubjectAndDefinition(text, chinese: chineseMeaning, english: englishDefinition, record: source)
            let normalized = TextNormalizer.normalized(text)
            guard try !fetch(Term.self).contains(where: { $0.normalizedTerm == normalized }) else {
                throw VocabularyServiceError.duplicateTerm(text)
            }
            let term = Term(
                term: text, termType: text.contains(" ") ? .phrase : .word,
                chineseMeaning: optionalText(chineseMeaning), englishDefinition: optionalText(englishDefinition),
                contextSentence: source.rawText, courseID: source.courseID, sourceRecordID: source.id,
                sourceType: source.sourceType, nextReviewAt: date, createdAt: date, updatedAt: date
            )
            context.insert(term)
            _ = try addOrigin(termID: term.id, record: source, at: date)
            try completeCuration(source, at: date)
            return WordNoteV2VersionedID(id: term.id, revision: term.revision)
        }
    }

    public func confirmCandidate(
        _ candidateID: UUID, expectedRevision: Int, expectedRecordRevision: Int,
        operationID: UUID, target: WordNoteV2ConfirmationTarget, at date: Date = Date()
    ) throws -> WordNoteV2VersionedID {
        try transaction {
            try validateDate(date)
            guard let candidate = try fetch(Candidate.self).first(where: { $0.id == candidateID }) else {
                throw WordNoteV2ContentError.missingEntity
            }
            if candidate.statusRaw == "saved", candidate.confirmationOperationID == operationID {
                guard candidate.savedLinkStateRaw == "resolved", let termID = candidate.savedTermID else {
                    throw WordNoteV2ContentError.savedTargetDeleted
                }
                let term = try term(termID)
                return WordNoteV2VersionedID(id: term.id, revision: term.revision)
            }
            try requireRevision(candidate.revision, expectedRevision)
            guard candidate.statusRaw == "pending", candidate.savedTermID == nil, candidate.savedLinkStateRaw == "none" else {
                throw WordNoteV2ContentError.candidateAlreadyHandled
            }
            let source = try record(candidate.inputRecordID)
            try requireRevision(source.revision, expectedRecordRevision)
            try requireEditableCuration(source)
            guard candidate.analysisGeneration == source.analysisGeneration else { throw WordNoteV2ContentError.invalidState }
            let text = candidate.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard LookupDirectionDetector.isEnglishVocabularyTerm(text) else { throw VocabularyServiceError.englishTermRequired(text) }
            let normalized = TextNormalizer.normalized(text)
            let term: Term
            let isNew: Bool
            switch target {
            case .createNew:
                try validateSubjectAndDefinition(text, chinese: candidate.chineseMeaning, english: candidate.englishDefinition, record: source)
                guard try !fetch(Term.self).contains(where: { $0.normalizedTerm == normalized }) else {
                    throw VocabularyServiceError.duplicateTerm(text)
                }
                try validateText([candidate.aiContextExplanation, candidate.exampleSentence])
                term = Term(
                    term: text, termType: candidate.termType, chineseMeaning: optionalText(candidate.chineseMeaning),
                    englishDefinition: optionalText(candidate.englishDefinition), aiContextExplanation: optionalText(candidate.aiContextExplanation),
                    exampleSentence: optionalText(candidate.exampleSentence), contextSentence: source.rawText,
                    courseID: source.courseID, sourceRecordID: source.id, sourceType: source.sourceType,
                    category: candidate.category, importance: candidate.importance, nextReviewAt: date, createdAt: date, updatedAt: date
                )
                context.insert(term)
                isNew = true
            case .linkExisting(let termID, let expectedTermRevision):
                term = try self.term(termID)
                try requireRevision(term.revision, expectedTermRevision)
                guard term.normalizedTerm == normalized,
                      LookupDirectionDetector.isEnglishVocabularyTerm(term.term) else { throw WordNoteV2ContentError.invalidState }
                try validateSubjectAndDefinition(term.term, chinese: term.chineseMeaning, english: term.englishDefinition, record: source)
                isNew = false
            }
            let changedRelations = try addOrigin(termID: term.id, record: source, at: date)
            if !isNew, changedRelations { try touch(term, at: date) }
            candidate.statusRaw = "saved"
            candidate.savedTermID = term.id
            candidate.savedLinkStateRaw = "resolved"
            candidate.confirmationOperationID = operationID
            candidate.revision = try increment(candidate.revision)
            candidate.updatedAt = date
            try completeCuration(source, at: date)
            return WordNoteV2VersionedID(id: term.id, revision: term.revision)
        }
    }
}
