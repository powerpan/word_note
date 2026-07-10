import Foundation
import Observation
import SwiftData

@MainActor
@Observable
public final class QuickAddAnalysisQueue {
    public typealias AnalysisHandler = @MainActor (AIAnalysisRequest) async throws -> AIAnalysisResult

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let analysisHandler: AnalysisHandler
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    private var queuedRecords: [QueuedAnalysisRecord] = []
    private var isProcessingAnalysisQueue = false

    public var activeAnalysisTitle: String?
    public var statusMessage: String?
    public var errorMessage: String?
    public var latestAIExplanation: AIExplanationPreview?

    public init(
        modelContext: ModelContext,
        analysisHandler: AnalysisHandler? = nil
    ) {
        self.modelContext = modelContext
        self.analysisHandler = analysisHandler ?? Self.performLiveAnalysis
    }

    public var queuedCount: Int {
        queuedRecords.count
    }

    public var isBusy: Bool {
        isProcessingAnalysisQueue || !queuedRecords.isEmpty
    }

    public var queueStatusText: String {
        if let activeAnalysisTitle {
            return "Analyzing: \(activeAnalysisTitle)"
        }
        return "Preparing AI analysis..."
    }

    @discardableResult
    public func enqueue(
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

        let normalizedText = TextNormalizer.normalized(rawText)
        if let queuedRecord = try findPersistedQueuedRecord(normalizedText: normalizedText) {
            statusMessage = "Already queued for AI analysis: \(queuedRecord.rawText)"
            errorMessage = nil
            return .alreadyQueued(queuedRecord)
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

    @discardableResult
    public func recoverPendingAnalyses() throws -> Int {
        let persistedRecords = try modelContext.fetch(FetchDescriptor<InputRecordModel>())
            .filter { $0.status == .analyzing }
            .sorted { $0.createdAt < $1.createdAt }
        let queuedIDs = Set(queuedRecords.map { $0.record.id })
        let activeID = processingTask == nil ? nil : persistedRecords.first { $0.rawText == activeAnalysisTitle }?.id
        let courses = try modelContext.fetch(FetchDescriptor<CourseModel>())
        let courseNames = Dictionary(uniqueKeysWithValues: courses.map { ($0.id, $0.courseName) })

        let recoveredRecords = persistedRecords.filter { record in
            record.id != activeID && !queuedIDs.contains(record.id)
        }
        queuedRecords.append(contentsOf: recoveredRecords.map { record in
            QueuedAnalysisRecord(
                record: record,
                courseName: record.courseID.flatMap { courseNames[$0] }
            )
        })

        if !recoveredRecords.isEmpty {
            statusMessage = "Recovered \(recoveredRecords.count) queued analysis request\(recoveredRecords.count == 1 ? "" : "s")."
            errorMessage = nil
        }
        processNextQueuedAnalysisIfNeeded()
        return recoveredRecords.count
    }

    func waitUntilIdle(timeoutNanoseconds: UInt64 = 3_000_000_000) async throws {
        let startedAt = ContinuousClock.now
        while isBusy {
            if ContinuousClock.now - startedAt > .nanoseconds(Int64(timeoutNanoseconds)) {
                throw QuickAddQueueWaitError.timedOut
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func findPersistedQueuedRecord(normalizedText: String) throws -> InputRecordModel? {
        try modelContext.fetch(FetchDescriptor<InputRecordModel>())
            .first { $0.status == .analyzing && $0.normalizedText == normalizedText }
    }

    private func processNextQueuedAnalysisIfNeeded() {
        guard !isProcessingAnalysisQueue, !queuedRecords.isEmpty else { return }

        isProcessingAnalysisQueue = true
        let queuedRecord = queuedRecords.removeFirst()
        activeAnalysisTitle = queuedRecord.record.rawText

        processingTask = Task { @MainActor in
            let service = InputRecordService(modelContext: modelContext)

            do {
                let result = try await analysisHandler(
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
            processingTask = nil
            processNextQueuedAnalysisIfNeeded()
        }
    }

    private static func performLiveAnalysis(_ request: AIAnalysisRequest) async throws -> AIAnalysisResult {
        guard let apiKey = DeepSeekAPIKeyResolver.resolve() else {
            throw AIAnalysisError.missingAPIKey
        }
        return try await AIAnalysisService(
            client: DeepSeekChatClient(apiKey: apiKey)
        ).analyze(request)
    }
}

public enum QuickAddEnqueueResult {
    case queued(InputRecordModel)
    case alreadyQueued(InputRecordModel)
    case duplicateHit(TermModel)
}

private struct QueuedAnalysisRecord: Identifiable {
    let id = UUID()
    let record: InputRecordModel
    let courseName: String?
}

enum QuickAddQueueWaitError: Error {
    case timedOut
}

public struct AIExplanationPreview {
    public let id: UUID
    public let rawText: String
    public let sentenceMeaning: String?
    public let candidates: [AIExplanationCandidatePreview]

    public init(
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

    public init(rawText: String, existingTerm: TermModel) {
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

public struct AIExplanationCandidatePreview: Identifiable {
    public let id: String
    public let term: String
    public let importance: Importance
    public let chineseMeaning: String?
    public let englishDefinition: String?
    public let aiContextExplanation: String?

    public init(candidate: AIAnalysisCandidate) {
        id = "\(TextNormalizer.normalized(candidate.term))-\(candidate.termType.rawValue)-\(candidate.importance.rawValue)"
        term = candidate.term
        importance = candidate.importance
        chineseMeaning = Self.nonBlank(candidate.chineseMeaning)
        englishDefinition = Self.nonBlank(candidate.englishDefinition)
        aiContextExplanation = Self.nonBlank(candidate.aiContextExplanation)
    }

    public init(term: TermModel) {
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
