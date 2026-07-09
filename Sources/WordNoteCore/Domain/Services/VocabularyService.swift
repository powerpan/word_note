import Foundation
import SwiftData

public enum VocabularyServiceError: LocalizedError, Equatable {
    case duplicateTerm(String)
    case missingDefinition(String)
    case emptySelection

    public var errorDescription: String? {
        switch self {
        case .duplicateTerm(let term):
            return "Vocabulary already contains '\(term)'."
        case .missingDefinition(let term):
            return "'\(term)' needs a Chinese meaning or English definition."
        case .emptySelection:
            return "Select at least one candidate."
        }
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

        var descriptor = FetchDescriptor<TermModel>(
            predicate: #Predicate { term in
                term.normalizedTerm == normalizedTerm
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    @discardableResult
    public func bumpDuplicateHit(
        _ term: TermModel,
        at date: Date = Date(),
        wrongCountCooldown: TimeInterval = 10 * 60
    ) throws -> TermModel {
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
        sourceRecord: InputRecordModel,
        allowDuplicates: Bool = false
    ) throws -> [TermModel] {
        guard !candidates.isEmpty else {
            throw VocabularyServiceError.emptySelection
        }

        let existingTerms = try modelContext.fetch(FetchDescriptor<TermModel>())
        let existingNormalizedTerms = Set(existingTerms.map(\.normalizedTerm))

        for candidate in candidates {
            let hasDefinition = !TextNormalizer.isBlank(candidate.chineseMeaning ?? "") ||
                !TextNormalizer.isBlank(candidate.englishDefinition ?? "")
            guard hasDefinition else {
                throw VocabularyServiceError.missingDefinition(candidate.term)
            }

            if !allowDuplicates, existingNormalizedTerms.contains(candidate.normalizedTerm) {
                throw VocabularyServiceError.duplicateTerm(candidate.term)
            }
        }

        let now = Date()
        let terms = candidates.map { candidate in
            TermModel(
                term: candidate.term,
                termType: candidate.termType,
                chineseMeaning: candidate.chineseMeaning,
                englishDefinition: candidate.englishDefinition,
                aiContextExplanation: candidate.aiContextExplanation,
                exampleSentence: candidate.exampleSentence,
                contextSentence: sourceRecord.rawText,
                courseID: sourceRecord.courseID,
                sourceRecordID: sourceRecord.id,
                sourceType: sourceRecord.sourceType,
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

        for term in terms {
            modelContext.insert(term)
        }

        for candidate in candidates {
            candidate.markSaved(at: now)
        }

        try updateCompletionStatus(for: sourceRecord, at: now)
        try modelContext.save()
        return terms
    }

    public func ignore(_ candidates: [CandidateTermModel], sourceRecord: InputRecordModel) throws {
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
        let trimmedTerm = termText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TextNormalizer.isBlank(trimmedTerm) else {
            throw InputRecordValidationError.blankRawText
        }

        let hasDefinition = !TextNormalizer.isBlank(chineseMeaning ?? "") ||
            !TextNormalizer.isBlank(englishDefinition ?? "")
        guard hasDefinition else {
            throw VocabularyServiceError.missingDefinition(trimmedTerm)
        }

        term.term = trimmedTerm
        term.normalizedTerm = TextNormalizer.normalized(trimmedTerm)
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
        modelContext.delete(term)
        try modelContext.save()
    }

    private func updateCompletionStatus(for record: InputRecordModel, at date: Date) throws {
        let recordID = record.id
        let descriptor = FetchDescriptor<CandidateTermModel>(
            predicate: #Predicate { candidate in
                candidate.inputRecordID == recordID
            }
        )
        let candidates = try modelContext.fetch(descriptor)
        if !candidates.isEmpty, candidates.allSatisfy({ $0.status != .pending }) {
            record.status = .completed
            record.touch(date)
        }
    }

    private func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
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
