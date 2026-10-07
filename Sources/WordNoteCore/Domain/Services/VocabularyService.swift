import Foundation
import SwiftData

public enum VocabularyServiceError: LocalizedError, Equatable {
    case duplicateTerm(String)
    case missingDefinition(String)
    case emptySelection
    case candidateSourceMismatch(String)
    case englishTermRequired(String)
    case chineseMeaningRequired(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateTerm(let term):
            return "Vocabulary already contains '\(term)'."
        case .missingDefinition(let term):
            return "'\(term)' needs a Chinese meaning or English definition."
        case .emptySelection:
            return "Select at least one candidate."
        case .candidateSourceMismatch(let term):
            return "'\(term)' does not belong to this input record."
        case .englishTermRequired(let term):
            return "'\(term)' must be an English word or expression. Keep Chinese text in the meaning or context."
        case .chineseMeaningRequired(let term):
            return "'\(term)' needs a Chinese meaning for a Chinese-to-English lookup."
        }
    }
}

public struct CandidateConfirmation {
    public let candidates: [CandidateTermModel]
    public let sourceRecord: InputRecordModel

    public init(candidates: [CandidateTermModel], sourceRecord: InputRecordModel) {
        self.candidates = candidates
        self.sourceRecord = sourceRecord
    }
}

@MainActor
public struct VocabularyService {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func findExactTerm(rawText: String) throws -> TermModel? {
        let normalizedTerm = TextNormalizer.normalized(rawText)
        return try findExactTerm(normalizedTerm: normalizedTerm)
    }

    public func findExactTerm(normalizedTerm: String) throws -> TermModel? {
        let normalizedTerm = TextNormalizer.normalized(normalizedTerm)
        guard !TextNormalizer.isBlank(normalizedTerm) else { return nil }

        return try modelContext.fetch(FetchDescriptor<TermModel>())
            .first { $0.normalizedTerm == normalizedTerm }
    }

    @discardableResult
    public func bumpDuplicateHit(
        _ term: TermModel,
        at date: Date = Date(),
        wrongCountCooldown: TimeInterval = 10 * 60
    ) throws -> TermModel {
        try WordNoteWriteGate.check(modelContext)
        let previousDuplicateHitAt = term.lastDuplicateHitAt

        term.nextReviewAt = date
        term.importance = bumpedImportance(term.importance)
        switch term.masteryLevel {
        case .familiar, .mastered:
            term.masteryLevel = .vague
        case .new, .vague:
            break
        }
        term.correctStreak = 0
        term.duplicateHitCount += 1
        if shouldIncreaseWrongCount(
            previousDuplicateHitAt: previousDuplicateHitAt,
            date: date,
            cooldown: wrongCountCooldown
        ) {
            term.wrongCount += 1
        }
        term.lastDuplicateHitAt = date
        term.touch(date)

        try modelContext.save()
        return term
    }

    @discardableResult
    public func createTerms(
        from candidates: [CandidateTermModel],
        sourceRecord: InputRecordModel
    ) throws -> [TermModel] {
        try confirmCandidates([
            CandidateConfirmation(candidates: candidates, sourceRecord: sourceRecord)
        ])
    }

    @discardableResult
    public func confirmCandidates(_ confirmations: [CandidateConfirmation]) throws -> [TermModel] {
        try WordNoteWriteGate.check(modelContext)
        guard !confirmations.isEmpty,
              confirmations.allSatisfy({ !$0.candidates.isEmpty })
        else {
            throw VocabularyServiceError.emptySelection
        }

        let existingTerms = try modelContext.fetch(FetchDescriptor<TermModel>())
        var seenNormalizedTerms = Set(existingTerms.map(\.normalizedTerm))

        for confirmation in confirmations {
            for candidate in confirmation.candidates {
                guard candidate.inputRecordID == confirmation.sourceRecord.id else {
                    throw VocabularyServiceError.candidateSourceMismatch(candidate.term)
                }
                try validateVocabularySubject(candidate.term)
                try validateChineseMeaningIfNeeded(
                    candidate.chineseMeaning,
                    term: candidate.term,
                    sourceRecord: confirmation.sourceRecord
                )

                let hasDefinition = !TextNormalizer.isBlank(candidate.chineseMeaning ?? "") ||
                    !TextNormalizer.isBlank(candidate.englishDefinition ?? "")
                guard hasDefinition else {
                    throw VocabularyServiceError.missingDefinition(candidate.term)
                }

                let normalizedTerm = TextNormalizer.normalized(candidate.term)
                guard !seenNormalizedTerms.contains(normalizedTerm) else {
                    throw VocabularyServiceError.duplicateTerm(candidate.term)
                }
                seenNormalizedTerms.insert(normalizedTerm)
            }
        }

        let now = Date()
        let terms = confirmations.flatMap { confirmation in
            confirmation.candidates.map { candidate in
                TermModel(
                    term: candidate.term.trimmingCharacters(in: .whitespacesAndNewlines),
                    termType: candidate.termType,
                    chineseMeaning: normalizedOptional(candidate.chineseMeaning),
                    englishDefinition: normalizedOptional(candidate.englishDefinition),
                    aiContextExplanation: normalizedOptional(candidate.aiContextExplanation),
                    exampleSentence: normalizedOptional(candidate.exampleSentence),
                    contextSentence: confirmation.sourceRecord.rawText,
                    courseID: confirmation.sourceRecord.courseID,
                    sourceRecordID: confirmation.sourceRecord.id,
                    sourceType: confirmation.sourceRecord.sourceType,
                    tags: [],
                    category: candidate.category,
                    importance: candidate.importance,
                    masteryLevel: .new,
                    reviewCount: 0,
                    wrongCount: 0,
                    nextReviewAt: now,
                    createdAt: now,
                    updatedAt: now
                )
            }
        }

        do {
            terms.forEach(modelContext.insert)

            for confirmation in confirmations {
                confirmation.candidates.forEach { $0.markSaved(at: now) }
                try updateCompletionStatus(for: confirmation.sourceRecord, at: now)
            }

            try modelContext.save()
            return terms
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    @discardableResult
    public func createManualTerm(
        termText: String,
        chineseMeaning: String?,
        englishDefinition: String?,
        sourceRecord: InputRecordModel
    ) throws -> TermModel {
        try WordNoteWriteGate.check(modelContext)
        let trimmedTerm = termText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TextNormalizer.isBlank(trimmedTerm) else {
            throw InputRecordValidationError.blankRawText
        }
        try validateVocabularySubject(trimmedTerm)
        try validateChineseMeaningIfNeeded(
            chineseMeaning,
            term: trimmedTerm,
            sourceRecord: sourceRecord
        )

        let normalizedTerm = TextNormalizer.normalized(trimmedTerm)
        guard try findExactTerm(normalizedTerm: normalizedTerm) == nil else {
            throw VocabularyServiceError.duplicateTerm(trimmedTerm)
        }

        let normalizedChineseMeaning = normalizedOptional(chineseMeaning)
        let normalizedEnglishDefinition = normalizedOptional(englishDefinition)
        guard normalizedChineseMeaning != nil || normalizedEnglishDefinition != nil else {
            throw VocabularyServiceError.missingDefinition(trimmedTerm)
        }

        let now = Date()
        let term = TermModel(
            term: trimmedTerm,
            termType: trimmedTerm.contains(" ") ? .phrase : .word,
            chineseMeaning: normalizedChineseMeaning,
            englishDefinition: normalizedEnglishDefinition,
            contextSentence: sourceRecord.rawText,
            courseID: sourceRecord.courseID,
            sourceRecordID: sourceRecord.id,
            sourceType: sourceRecord.sourceType,
            nextReviewAt: now,
            createdAt: now,
            updatedAt: now
        )

        do {
            modelContext.insert(term)
            try completeRecordWhenNoPendingCandidates(sourceRecord, at: now)
            try modelContext.save()
            return term
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    public func ignore(_ candidates: [CandidateTermModel], sourceRecord: InputRecordModel) throws {
        try WordNoteWriteGate.check(modelContext)
        let now = Date()
        for candidate in candidates {
            candidate.markIgnored(at: now)
        }
        try updateCompletionStatus(for: sourceRecord, at: now)
        try modelContext.save()
    }

    public func updateTerm(
        _ term: TermModel,
        termText: String,
        termType: TermType,
        chineseMeaning: String?,
        englishDefinition: String?,
        aiContextExplanation: String?,
        exampleSentence: String?,
        contextSentence: String?,
        courseID: UUID?,
        sourceType: SourceType,
        category: TermCategory,
        importance: Importance,
        masteryLevel: MasteryLevel
    ) throws {
        try WordNoteWriteGate.check(modelContext)
        let trimmedTerm = termText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TextNormalizer.isBlank(trimmedTerm) else {
            throw InputRecordValidationError.blankRawText
        }
        try validateVocabularySubject(trimmedTerm)

        let hasDefinition = !TextNormalizer.isBlank(chineseMeaning ?? "") ||
            !TextNormalizer.isBlank(englishDefinition ?? "")
        guard hasDefinition else {
            throw VocabularyServiceError.missingDefinition(trimmedTerm)
        }

        let normalizedTerm = TextNormalizer.normalized(trimmedTerm)
        if let duplicate = try findExactTerm(normalizedTerm: normalizedTerm), duplicate.id != term.id {
            throw VocabularyServiceError.duplicateTerm(trimmedTerm)
        }

        term.term = trimmedTerm
        term.normalizedTerm = normalizedTerm
        term.termType = termType
        term.chineseMeaning = normalizedOptional(chineseMeaning)
        term.englishDefinition = normalizedOptional(englishDefinition)
        term.aiContextExplanation = normalizedOptional(aiContextExplanation)
        term.exampleSentence = normalizedOptional(exampleSentence)
        term.contextSentence = normalizedOptional(contextSentence)
        term.courseID = courseID
        term.sourceType = sourceType
        term.category = category
        term.importance = importance
        term.masteryLevel = masteryLevel
        term.touch()
        try modelContext.save()
    }

    public func delete(_ term: TermModel) throws {
        try WordNoteWriteGate.check(modelContext)
        let termID = term.id
        let reviewEvents = try modelContext.fetch(FetchDescriptor<ReviewEventModel>())
            .filter { $0.termID == termID }
        reviewEvents.forEach(modelContext.delete)
        modelContext.delete(term)

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func updateCompletionStatus(for record: InputRecordModel, at date: Date) throws {
        let recordID = record.id
        let candidates = try modelContext.fetch(FetchDescriptor<CandidateTermModel>())
            .filter { $0.inputRecordID == recordID }
        if !candidates.isEmpty, candidates.allSatisfy({ $0.status != .pending }) {
            record.status = .completed
            record.touch(date)
        }
    }

    private func completeRecordWhenNoPendingCandidates(_ record: InputRecordModel, at date: Date) throws {
        let recordID = record.id
        let candidates = try modelContext.fetch(FetchDescriptor<CandidateTermModel>())
            .filter { $0.inputRecordID == recordID }
        if candidates.allSatisfy({ $0.status != .pending }) {
            record.status = .completed
            record.touch(date)
        }
    }

    private func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
    }

    private func validateVocabularySubject(_ term: String) throws {
        guard LookupDirectionDetector.isEnglishVocabularyTerm(term) else {
            throw VocabularyServiceError.englishTermRequired(term)
        }
    }

    private func validateChineseMeaningIfNeeded(
        _ chineseMeaning: String?,
        term: String,
        sourceRecord: InputRecordModel
    ) throws {
        guard LookupDirectionDetector.detect(sourceRecord.rawText) == .chineseToEnglish else {
            return
        }
        guard !TextNormalizer.isBlank(chineseMeaning ?? "") else {
            throw VocabularyServiceError.chineseMeaningRequired(term)
        }
    }

    private func bumpedImportance(_ importance: Importance) -> Importance {
        switch importance {
        case .low:
            return .medium
        case .medium:
            return .high
        case .high:
            return .high
        }
    }

    private func shouldIncreaseWrongCount(
        previousDuplicateHitAt: Date?,
        date: Date,
        cooldown: TimeInterval
    ) -> Bool {
        guard let previousDuplicateHitAt else { return true }
        return date.timeIntervalSince(previousDuplicateHitAt) >= cooldown
    }
}
