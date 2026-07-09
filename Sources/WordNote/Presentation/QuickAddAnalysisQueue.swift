import Foundation
import Observation
import SwiftData
import WordNoteCore

@MainActor
@Observable
final class QuickAddAnalysisQueue {
    @ObservationIgnored private let modelContext: ModelContext
    private var queuedRecords: [QueuedAnalysisRecord] = []
    private var isProcessingAnalysisQueue = false

    var activeAnalysisTitle: String?
    var statusMessage: String?
    var errorMessage: String?
    var latestAIExplanation: AIExplanationPreview?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    var queuedCount: Int {
        queuedRecords.count
    }

    var isBusy: Bool {
        isProcessingAnalysisQueue || !queuedRecords.isEmpty
    }

    var queueStatusText: String {
        if let activeAnalysisTitle {
            return "Analyzing: \(activeAnalysisTitle)"
        }
        return "Preparing AI analysis..."
    }

    @discardableResult
    func enqueue(
        rawText: String,
        courseID: UUID?,
        courseName: String?,
        sourceType: SourceType,
        note: String?
    ) throws -> QuickAddEnqueueResult {
        let vocabularyService = VocabularyService(modelContext: modelContext)
        if let existingTerm = try vocabularyService.findExactTerm(rawText: rawText) {
            let bumpedTerm = try vocabularyService.bumpDuplicateHit(existingTerm)
            latestAIExplanation = AIExplanationPreview(
                rawText: rawText,
                existingTerm: bumpedTerm
            )
            statusMessage = "Already in vocabulary: \(bumpedTerm.term). Added to today's review."
            errorMessage = nil
            return .duplicateHit(bumpedTerm)
        }

        let service = InputRecordService(modelContext: modelContext)
        let createdRecord = try service.createAnalyzing(
            rawText: rawText,
            courseID: courseID,
            sourceType: sourceType,
            note: note
        )

        queuedRecords.append(
            QueuedAnalysisRecord(record: createdRecord, courseName: courseName)
        )
        statusMessage = "Queued for AI analysis: \(createdRecord.rawText)"
        errorMessage = nil
        processNextQueuedAnalysisIfNeeded()
        return .queued(createdRecord)
    }

    private func processNextQueuedAnalysisIfNeeded() {
        guard !isProcessingAnalysisQueue, !queuedRecords.isEmpty else { return }

        isProcessingAnalysisQueue = true
        let queuedRecord = queuedRecords.removeFirst()
        activeAnalysisTitle = queuedRecord.record.rawText

        Task { @MainActor in
            let service = InputRecordService(modelContext: modelContext)

            do {
                guard let apiKey = DeepSeekAPIKeyResolver.resolve() else {
                    try service.markFailed(
                        queuedRecord.record,
                        summary: AIAnalysisError.missingAPIKey.localizedDescription
                    )
                    throw AIAnalysisError.missingAPIKey
                }

                let analysisService = AIAnalysisService(
                    client: DeepSeekChatClient(apiKey: apiKey)
                )
                let result = try await analysisService.analyze(
                    AIAnalysisRequest(
                        rawText: queuedRecord.record.rawText,
                        courseName: queuedRecord.courseName,
                        sourceType: queuedRecord.record.sourceType,
                        userNote: queuedRecord.record.note
                    )
                )
                let candidates = try service.applyAnalysisResult(result, to: queuedRecord.record)

                latestAIExplanation = AIExplanationPreview(
                    rawText: queuedRecord.record.rawText,
                    sentenceMeaning: result.sentenceMeaning,
                    candidates: result.candidates.map(AIExplanationCandidatePreview.init(candidate:))
                )
                statusMessage = "Analyzed \(queuedRecord.record.rawText). Candidates: \(candidates.count)"
                errorMessage = nil
            } catch {
                if queuedRecord.record.status != .failed {
                    try? service.markFailed(queuedRecord.record, summary: error.localizedDescription)
                }
                statusMessage = nil
                errorMessage = "Analysis failed for \(queuedRecord.record.rawText): \(error.localizedDescription)"
            }

            isProcessingAnalysisQueue = false
            activeAnalysisTitle = nil
            processNextQueuedAnalysisIfNeeded()
        }
    }
}

enum QuickAddEnqueueResult {
    case queued(InputRecordModel)
    case duplicateHit(TermModel)
}

private struct QueuedAnalysisRecord: Identifiable {
    let id = UUID()
    let record: InputRecordModel
    let courseName: String?
}

struct AIExplanationPreview {
    let id: UUID
    let rawText: String
    let sentenceMeaning: String?
    let candidates: [AIExplanationCandidatePreview]

    init(
        id: UUID = UUID(),
        rawText: String,
        sentenceMeaning: String?,
        candidates: [AIExplanationCandidatePreview]
    ) {
        self.id = id
        self.rawText = rawText
        self.sentenceMeaning = Self.nonBlank(sentenceMeaning)
        self.candidates = candidates
    }

    init(rawText: String, existingTerm: TermModel) {
        self.init(
            rawText: rawText.trimmingCharacters(in: .whitespacesAndNewlines),
            sentenceMeaning: nil,
            candidates: [AIExplanationCandidatePreview(term: existingTerm)]
        )
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return TextNormalizer.isBlank(trimmed) ? nil : trimmed
    }
}

struct AIExplanationCandidatePreview: Identifiable {
    let id: String
    let term: String
    let importance: Importance
    let chineseMeaning: String?
    let englishDefinition: String?
    let aiContextExplanation: String?

    init(candidate: AIAnalysisCandidate) {
        id = "\(TextNormalizer.normalized(candidate.term))-\(candidate.termType.rawValue)-\(candidate.importance.rawValue)"
        term = candidate.term
        importance = candidate.importance
        chineseMeaning = Self.nonBlank(candidate.chineseMeaning)
        englishDefinition = Self.nonBlank(candidate.englishDefinition)
        aiContextExplanation = Self.nonBlank(candidate.aiContextExplanation)
    }

    init(term: TermModel) {
        id = term.id.uuidString
        self.term = term.term
        importance = term.importance
        chineseMeaning = Self.nonBlank(term.chineseMeaning)
        englishDefinition = Self.nonBlank(term.englishDefinition)
        aiContextExplanation = Self.nonBlank(term.aiContextExplanation)
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return TextNormalizer.isBlank(trimmed) ? nil : trimmed
    }
}
