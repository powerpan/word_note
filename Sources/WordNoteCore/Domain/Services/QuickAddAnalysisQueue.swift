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
    @ObservationIgnored private var processingID = UUID()
    private var queuedRecords: [QueuedAnalysisRecord] = []
    private var isProcessingAnalysisQueue = false

    public var activeAnalysisTitle: String?
    public var statusMessage: String?
    public var errorMessage: String?
    public var latestAIExplanation: AIExplanationPreview?
    public private(set) var isSuspended: Bool

    public init(
        modelContext: ModelContext,
        initiallySuspended: Bool = false,
        analysisHandler: AnalysisHandler? = nil
    ) {
        self.modelContext = modelContext
        self.analysisHandler = analysisHandler ?? Self.performLiveAnalysis
        isSuspended = initiallySuspended
    }

    public var queuedCount: Int {
        queuedRecords.count
    }

    public var isBusy: Bool {
        isProcessingAnalysisQueue || !queuedRecords.isEmpty
    }

    public var queueStatusText: String {
        if isSuspended { return "Analysis paused. Resume in Settings." }
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
        try WordNoteWriteGate.check(modelContext)
        let lookupDirection = LookupDirectionDetector.detect(rawText)
        let vocabularyService = VocabularyService(modelContext: modelContext)
        if lookupDirection == .englishToChinese,
           let existingTerm = try vocabularyService.findExactTerm(rawText: rawText) {
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
            statusMessage = "Already queued for \(lookupDirection.displayTitle.lowercased()): \(queuedRecord.rawText)"
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
        statusMessage = "Queued for \(lookupDirection.displayTitle.lowercased()): \(createdRecord.rawText)"
        errorMessage = nil
        processNextQueuedAnalysisIfNeeded()
        return .queued(createdRecord)
    }

    @discardableResult
    public func recoverPendingAnalyses() throws -> Int {
        try WordNoteWriteGate.check(modelContext)
        guard !isSuspended else { return 0 }
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

    public func suspendForRestore() {
        isSuspended = true
        processingID = UUID()
        processingTask?.cancel()
        processingTask = nil
        queuedRecords.removeAll()
        isProcessingAnalysisQueue = false
        activeAnalysisTitle = nil
        latestAIExplanation = nil
    }

    @discardableResult
    public func resumePendingAnalyses() throws -> Int {
        try WordNoteWriteGate.check(modelContext)
        isSuspended = false
        do { return try recoverPendingAnalyses() }
        catch {
            isSuspended = true
            throw error
        }
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
        guard !isSuspended, !isProcessingAnalysisQueue, !queuedRecords.isEmpty else { return }
        guard let ticket = try? WordNoteWriteGate.ticket(for: modelContext) else { return }

        isProcessingAnalysisQueue = true
        let queuedRecord = queuedRecords.removeFirst()
        activeAnalysisTitle = queuedRecord.record.rawText
        let operationID = UUID()
        processingID = operationID

        processingTask = Task { @MainActor in
            guard processingID == operationID, !Task.isCancelled else { return }
            let service = InputRecordService(modelContext: modelContext)
            let lookupDirection = LookupDirectionDetector.detect(queuedRecord.record.rawText)

            do {
                let outcome = try await service.analyze(
                    queuedRecord.record, request: AIAnalysisRequest(
                        rawText: queuedRecord.record.rawText,
                        courseName: queuedRecord.courseName,
                        sourceType: queuedRecord.record.sourceType,
                        userNote: queuedRecord.record.note,
                        lookupDirection: lookupDirection
                    ), ticket: ticket, using: analysisHandler
                )
                guard processingID == operationID else { return }
                let result = outcome.analysis

                latestAIExplanation = AIExplanationPreview(
                    rawText: queuedRecord.record.rawText,
                    sentenceMeaning: result.sentenceMeaning,
                    candidates: result.candidates.map(AIExplanationCandidatePreview.init(candidate:))
                )
                statusMessage = lookupDirection == .chineseToEnglish
                    ? "English candidates are ready in Inbox: \(outcome.candidateCount)"
                    : "Analyzed \(queuedRecord.record.rawText). Candidates: \(outcome.candidateCount)"
                errorMessage = nil
            } catch {
                guard processingID == operationID else { return }
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

public struct AIExplanationPreview: Sendable {
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

public struct AIExplanationCandidatePreview: Identifiable, Sendable {
    public let id: String
    public let term: String
    public let importance: Importance
    public let chineseMeaning: String?
    public let englishDefinition: String?
    public let aiContextExplanation: String?

    public init(
        id: String, term: String, importance: Importance, chineseMeaning: String?,
        englishDefinition: String?, aiContextExplanation: String? = nil
    ) {
        self.id = id
        self.term = term
        self.importance = importance
        self.chineseMeaning = Self.nonBlank(chineseMeaning)
        self.englishDefinition = Self.nonBlank(englishDefinition)
        self.aiContextExplanation = Self.nonBlank(aiContextExplanation)
    }

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
