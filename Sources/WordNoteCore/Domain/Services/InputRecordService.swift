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
        try WordNoteWriteGate.check(modelContext)
        record.markAnalyzing()
        try modelContext.save()
    }

    @discardableResult
    public func applyAnalysisResult(
        _ result: AIAnalysisResult,
        to record: InputRecordModel
    ) throws -> [CandidateTermModel] {
        try WordNoteWriteGate.check(modelContext)
        let recordID = record.id
        let existingCandidates = try modelContext.fetch(FetchDescriptor<CandidateTermModel>())
            .filter { $0.inputRecordID == recordID }
        let savedNormalizedTerms = Set(
            existingCandidates
                .filter { $0.status == .saved }
                .map(\.normalizedTerm)
        )

        existingCandidates
            .filter { $0.status != .saved }
            .forEach(modelContext.delete)

        record.markAnalyzed(sentenceMeaning: result.sentenceMeaning, inputType: result.inputType)

        let candidates = result.candidates
            .filter { !savedNormalizedTerms.contains(TextNormalizer.normalized($0.term)) }
            .map { candidate in
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
        try WordNoteWriteGate.check(modelContext)
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
        try WordNoteWriteGate.check(modelContext)
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
        try WordNoteWriteGate.check(modelContext)
        record.status = .ignored
        record.touch()
        try modelContext.save()
    }

    public func delete(_ record: InputRecordModel) throws {
        try WordNoteWriteGate.check(modelContext)
        let recordID = record.id
        let candidates = try modelContext.fetch(FetchDescriptor<CandidateTermModel>())
            .filter { $0.inputRecordID == recordID }
        let sourcedTerms = try modelContext.fetch(FetchDescriptor<TermModel>())
            .filter { $0.sourceRecordID == recordID }
        candidates.forEach(modelContext.delete)
        sourcedTerms.forEach { $0.sourceRecordID = nil }
        modelContext.delete(record)

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    @discardableResult
    public func analyze(
        _ record: InputRecordModel, request: AIAnalysisRequest,
        ticket expectedTicket: WordNoteWriteGate.Ticket? = nil,
        using handler: @MainActor (AIAnalysisRequest) async throws -> AIAnalysisResult
    ) async throws -> (analysis: AIAnalysisResult, candidateCount: Int) {
        try Task.checkCancellation()
        let ticket = try expectedTicket ?? WordNoteWriteGate.ticket(for: modelContext)
        try WordNoteWriteGate.check(modelContext, ticket: ticket)
        try markAnalyzing(record)
        do {
            let result = try await handler(request)
            try Task.checkCancellation()
            try WordNoteWriteGate.check(modelContext, ticket: ticket)
            let candidates = try applyAnalysisResult(result, to: record)
            return (analysis: result, candidateCount: candidates.count)
        } catch {
            // Invalidated callbacks must not write either a success or a failure status.
            try WordNoteWriteGate.check(modelContext, ticket: ticket)
            if !Task.isCancelled, !(error is CancellationError) {
                try markFailed(record, summary: error.localizedDescription)
            }
            throw error
        }
    }
}
