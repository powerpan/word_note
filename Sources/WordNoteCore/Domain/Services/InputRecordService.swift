import Foundation
import SwiftData

public enum InputRecordValidationError: LocalizedError, Equatable {
    case blankRawText

    public var errorDescription: String? {
        switch self {
        case .blankRawText:
            return "Raw text cannot be empty."
        }
    }
}

@MainActor
public struct InputRecordService {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    @discardableResult
    public func createDraft(
        rawText: String,
        courseID: UUID?,
        sourceType: SourceType,
        note: String?
    ) throws -> InputRecordModel {
        try createRecord(
            rawText: rawText,
            courseID: courseID,
            sourceType: sourceType,
            note: note,
            status: .draft
        )
    }

    @discardableResult
    public func createAnalyzing(
        rawText: String,
        courseID: UUID?,
        sourceType: SourceType,
        note: String?
    ) throws -> InputRecordModel {
        try createRecord(
            rawText: rawText,
            courseID: courseID,
            sourceType: sourceType,
            note: note,
            status: .analyzing
        )
    }

    public func markAnalyzing(_ record: InputRecordModel) throws {
        record.markAnalyzing()
        try modelContext.save()
    }

    @discardableResult
    public func applyAnalysisResult(
        _ result: AIAnalysisResult,
        to record: InputRecordModel
    ) throws -> [CandidateTermModel] {
        record.markAnalyzed(sentenceMeaning: result.sentenceMeaning, inputType: result.inputType)

        let candidates = result.candidates.map { candidate in
            CandidateTermModel(
                inputRecordID: record.id,
                term: candidate.term,
                termType: candidate.termType,
                needToLearn: candidate.needToLearn,
                importance: candidate.importance,
                category: candidate.category,
                reason: candidate.reason,
                chineseMeaning: candidate.chineseMeaning,
                englishDefinition: candidate.englishDefinition,
                aiContextExplanation: candidate.aiContextExplanation,
                exampleSentence: candidate.exampleSentence,
                relatedTerms: candidate.relatedTerms,
                confidence: candidate.confidence,
                status: .pending
            )
        }

        candidates.forEach(modelContext.insert)
        try modelContext.save()
        return candidates
    }

    public func markFailed(_ record: InputRecordModel, summary: String) throws {
        record.markFailed(summary)
        try modelContext.save()
    }

    private func createRecord(
        rawText: String,
        courseID: UUID?,
        sourceType: SourceType,
        note: String?,
        status: InputRecordStatus
    ) throws -> InputRecordModel {
        let trimmedRawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TextNormalizer.isBlank(trimmedRawText) else {
            throw InputRecordValidationError.blankRawText
        }

        let normalizedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = InputRecordModel(
            rawText: trimmedRawText,
            status: status,
            courseID: courseID,
            sourceType: sourceType,
            note: normalizedNote?.isEmpty == true ? nil : normalizedNote
        )

        modelContext.insert(record)
        try modelContext.save()
        return record
    }

    public func ignore(_ record: InputRecordModel) throws {
        record.status = .ignored
        record.touch()
        try modelContext.save()
    }

    public func delete(_ record: InputRecordModel) throws {
        modelContext.delete(record)
        try modelContext.save()
    }
}
