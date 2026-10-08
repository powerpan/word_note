import Foundation

public enum WordNoteV2AnalysisError: LocalizedError, Equatable {
    case staleAttempt
    case retryDeferred(until: Date)

    public var errorDescription: String? {
        switch self {
        case .staleAttempt: "This analysis no longer belongs to the current record. Its result was not saved."
        case .retryDeferred: "The analysis service requires a waiting period before retrying."
        }
    }
}

public struct WordNoteV2AnalysisJob: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let revision: Int
    public let rawText: String
    public let state: AnalysisQueueState
    public let autoRetryCount: Int
    public let nextAttemptAt: Date?
    public let errorSummary: String?
    public let createdAt: Date
}

/// Only immutable values cross the network suspension point.
public struct WordNoteV2AnalysisAttempt: Sendable {
    public let recordID: UUID
    public let captureID: UUID
    public let capturedVia: CaptureSurface
    public let revision: Int
    public let generation: Int
    public let attemptID: UUID
    public let request: AIAnalysisRequest
    public let autoRetryCount: Int
    fileprivate let ticket: WordNoteWriteGate.Ticket
}

extension WordNoteV2ContentService {
    public func analysisJobs() throws -> [WordNoteV2AnalysisJob] {
        try WordNoteWriteGate.check(context)
        return try fetch(Record.self).compactMap { record in
            guard let state = AnalysisQueueState(rawValue: record.queueStateRaw) else { throw WordNoteV2ContentError.invalidState }
            guard state != .none else { return nil }
            return WordNoteV2AnalysisJob(
                id: record.id, revision: record.revision, rawText: record.rawText, state: state,
                autoRetryCount: record.autoRetryCount, nextAttemptAt: record.nextAttemptAt,
                errorSummary: record.aiErrorSummary, createdAt: record.createdAt
            )
        }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func queueAnalysis(_ id: UUID, expectedRevision: Int, at date: Date = Date()) throws -> WordNoteV2VersionedID {
        try transaction {
            try validateDate(date)
            let record = try record(id)
            try requireRevision(record.revision, expectedRevision)
            guard let state = AnalysisQueueState(rawValue: record.queueStateRaw), record.status != .ignored else {
                throw WordNoteV2ContentError.invalidState
            }
            if state == .queued || state == .running { return .init(id: id, revision: record.revision) }
            if let next = record.nextAttemptAt, next > date { throw WordNoteV2AnalysisError.retryDeferred(until: next) }
            _ = try analysisRequest(record)
            record.analysisGeneration = try increment(record.analysisGeneration)
            record.queueStateRaw = AnalysisQueueState.queued.rawValue
            record.attemptID = nil
            record.nextAttemptAt = nil
            record.autoRetryCount = 0
            record.aiErrorSummary = nil
            try touchAnalysis(record, at: date)
            return .init(id: id, revision: record.revision)
        }
    }

    public func beginAnalysis(_ id: UUID, expectedRevision: Int, at date: Date = Date()) throws -> WordNoteV2AnalysisAttempt {
        try transaction {
            try validateDate(date)
            let record = try record(id)
            try requireRevision(record.revision, expectedRevision)
            guard record.queueStateRaw == "queued", record.status != .ignored,
                  (0...AnalysisRetryPolicy.maximumAutomaticRetries).contains(record.autoRetryCount) else {
                throw WordNoteV2ContentError.invalidState
            }
            if let next = record.nextAttemptAt, next > date { throw WordNoteV2AnalysisError.retryDeferred(until: next) }
            let request = try analysisRequest(record)
            guard let surface = CaptureSurface(rawValue: record.capturedViaRaw) else { throw WordNoteV2ContentError.invalidState }
            let ticket = try WordNoteWriteGate.ticket(for: context)
            let attemptID = UUID()
            record.attemptID = attemptID
            record.queueStateRaw = AnalysisQueueState.running.rawValue
            record.nextAttemptAt = nil
            try touchAnalysis(record, at: date)
            return WordNoteV2AnalysisAttempt(
                recordID: id, captureID: record.captureID, capturedVia: surface,
                revision: record.revision, generation: record.analysisGeneration,
                attemptID: attemptID, request: request, autoRetryCount: record.autoRetryCount, ticket: ticket
            )
        }
    }

    @discardableResult
    public func completeAnalysis(
        _ attempt: WordNoteV2AnalysisAttempt, result: AIAnalysisResult, at date: Date = Date()
    ) throws -> AIExplanationPreview {
        try transaction {
            try validateDate(date)
            let record = try currentAnalysis(attempt)
            do { try validateAnalysis(result, direction: attempt.request.lookupDirection) }
            catch { throw AIAnalysisError.invalidResponse }
            let existing = try candidates(for: record)
            var names = Set(existing.map(\.normalizedTerm))
            var additions: [Candidate] = []
            // Reanalysis must not overwrite manual curation or destroy saved-term links.
            for value in result.candidates where names.insert(TextNormalizer.normalized(value.term)).inserted {
                let candidate = Candidate(
                    inputRecordID: record.id, term: value.term.trimmingCharacters(in: .whitespacesAndNewlines),
                    termType: value.termType, needToLearn: value.needToLearn, importance: value.importance,
                    category: value.category, reason: optionalText(value.reason), chineseMeaning: optionalText(value.chineseMeaning),
                    englishDefinition: optionalText(value.englishDefinition), aiContextExplanation: optionalText(value.aiContextExplanation),
                    exampleSentence: optionalText(value.exampleSentence), relatedTerms: value.relatedTerms,
                    confidence: value.confidence, createdAt: date, updatedAt: date
                )
                candidate.analysisGeneration = record.analysisGeneration
                context.insert(candidate)
                additions.append(candidate)
            }
            try carryForwardPending(existing, record: record, at: date)
            let all = existing + additions
            record.inputType = result.inputType
            if record.sentenceMeaning == nil { record.sentenceMeaning = optionalText(result.sentenceMeaning) }
            record.status = !all.isEmpty && all.allSatisfy({ $0.status != .pending }) ? .completed : .analyzed
            record.analyzedAt = date
            record.queueStateRaw = AnalysisQueueState.none.rawValue
            record.attemptID = nil
            record.nextAttemptAt = nil
            record.aiErrorSummary = nil
            try touchAnalysis(record, at: date)
            return AIExplanationPreview(
                rawText: record.rawText, sentenceMeaning: record.sentenceMeaning,
                candidates: all.filter { $0.status != .ignored }.map {
                    AIExplanationCandidatePreview(
                        id: $0.id.uuidString, term: $0.term, importance: $0.importance,
                        chineseMeaning: $0.chineseMeaning, englishDefinition: $0.englishDefinition,
                        aiContextExplanation: $0.aiContextExplanation
                    )
                }
            )
        }
    }

    public func failAnalysis(
        _ attempt: WordNoteV2AnalysisAttempt, error: Error, at date: Date = Date()
    ) throws {
        try transaction {
            try validateDate(date)
            let record = try currentAnalysis(attempt)
            let decision = AnalysisRetryPolicy.decide(error, retries: record.autoRetryCount, at: date)
            let retryAt = decision.automaticRetryAt ?? decision.manualRetryNotBefore
            if let retryAt { try validateDate(retryAt) }
            record.queueStateRaw = decision.automaticRetryAt == nil ? "failed" : "queued"
            if decision.automaticRetryAt != nil { record.autoRetryCount = try increment(record.autoRetryCount) }
            record.nextAttemptAt = retryAt
            record.attemptID = nil
            record.aiErrorSummary = decision.summary
            try carryForwardPending(candidates(for: record), record: record, at: date)
            try touchAnalysis(record, at: date)
        }
    }

    public func cancelAnalysis(_ id: UUID, expectedRevision: Int, at date: Date = Date()) throws {
        try transaction {
            try validateDate(date)
            let record = try record(id)
            try requireRevision(record.revision, expectedRevision)
            guard ["queued", "running"].contains(record.queueStateRaw) else { throw WordNoteV2ContentError.invalidState }
            record.analysisGeneration = try increment(record.analysisGeneration)
            record.queueStateRaw = "cancelled"
            record.attemptID = nil
            // Cancelling a delayed retry must not bypass the provider's waiting period.
            if record.nextAttemptAt.map({ $0 <= date }) ?? false { record.nextAttemptAt = nil }
            record.aiErrorSummary = nil
            try carryForwardPending(candidates(for: record), record: record, at: date)
            try touchAnalysis(record, at: date)
        }
    }

    /// The queue must persist its pause before calling this after an interrupted request.
    @discardableResult
    func recoverInterruptedAnalyses(at date: Date = Date()) throws -> Int {
        try transaction {
            try validateDate(date)
            let interrupted = try fetch(Record.self).filter { $0.queueStateRaw == "running" }
            for record in interrupted {
                record.analysisGeneration = try increment(record.analysisGeneration)
                record.queueStateRaw = "queued"
                record.attemptID = nil
                record.nextAttemptAt = nil
                record.aiErrorSummary = "Analysis was interrupted. Resume explicitly; the provider may already have processed the request."
                try carryForwardPending(candidates(for: record), record: record, at: date)
                try touchAnalysis(record, at: date)
            }
            return interrupted.count
        }
    }

    private func currentAnalysis(_ attempt: WordNoteV2AnalysisAttempt) throws -> Record {
        try WordNoteWriteGate.check(context, ticket: attempt.ticket)
        guard let record = try fetch(Record.self).first(where: { $0.id == attempt.recordID }),
              record.revision == attempt.revision, record.analysisGeneration == attempt.generation,
              record.attemptID == attempt.attemptID, record.queueStateRaw == "running", record.status != .ignored else {
            throw WordNoteV2AnalysisError.staleAttempt
        }
        return record
    }

    private func analysisRequest(_ record: Record) throws -> AIAnalysisRequest {
        guard let direction = LookupDirection(rawValue: record.resolvedLookupDirectionRaw),
              let source = SourceType(rawValue: record.sourceTypeRaw),
              !TextNormalizer.isBlank(record.rawText) else { throw WordNoteV2ContentError.invalidState }
        guard record.rawText.count <= AIAnalysisService.maximumInputCharacters else {
            throw AIAnalysisError.inputTooLong(maxCharacters: AIAnalysisService.maximumInputCharacters)
        }
        return AIAnalysisRequest(
            rawText: record.rawText, courseName: try record.courseID.map { try course($0).courseName },
            sourceType: source, userNote: record.note, lookupDirection: direction
        )
    }

    private func validateAnalysis(_ result: AIAnalysisResult, direction: LookupDirection) throws {
        guard result.candidates.count <= 1_000 else { throw AIAnalysisError.invalidResponse }
        try validateText([result.sentenceMeaning])
        var names = Set<String>()
        for candidate in result.candidates {
            guard LookupDirectionDetector.isEnglishVocabularyTerm(candidate.term),
                  names.insert(TextNormalizer.normalized(candidate.term)).inserted,
                  candidate.confidence.isFinite, (0...1).contains(candidate.confidence),
                  candidate.relatedTerms.count <= 10_000,
                  direction != .chineseToEnglish || !TextNormalizer.isBlank(candidate.chineseMeaning ?? "") else {
                throw AIAnalysisError.invalidResponse
            }
            try validateText([candidate.term, candidate.reason, candidate.chineseMeaning, candidate.englishDefinition,
                              candidate.aiContextExplanation, candidate.exampleSentence] + candidate.relatedTerms.map(Optional.some))
        }
        if direction == .chineseToEnglish, result.candidates.isEmpty { throw AIAnalysisError.invalidResponse }
    }

    private func candidates(for record: Record) throws -> [Candidate] {
        try fetch(Candidate.self).filter { $0.inputRecordID == record.id }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }

    private func carryForwardPending(_ candidates: [Candidate], record: Record, at date: Date) throws {
        for candidate in candidates where candidate.status == .pending && candidate.analysisGeneration != record.analysisGeneration {
            candidate.analysisGeneration = record.analysisGeneration
            candidate.revision = try increment(candidate.revision)
            candidate.updatedAt = date
        }
    }

    private func touchAnalysis(_ record: Record, at date: Date) throws {
        record.revision = try increment(record.revision)
        record.updatedAt = date
    }
}
