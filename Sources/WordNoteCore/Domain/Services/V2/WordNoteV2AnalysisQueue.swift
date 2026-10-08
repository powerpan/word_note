import Foundation
import Observation
import SwiftData

@MainActor
@Observable
public final class WordNoteV2AnalysisQueue {
    public typealias AnalysisHandler = @MainActor (AIAnalysisRequest) async throws -> AIAnalysisResult

    @ObservationIgnored private let content: WordNoteV2ContentService
    @ObservationIgnored private let analyze: AnalysisHandler
    @ObservationIgnored private let persistPause: @MainActor () throws -> Void
    @ObservationIgnored private let authorizeResume: @MainActor () throws -> Void
    @ObservationIgnored private let validateSelection: @MainActor () throws -> Void
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sleep: @MainActor (TimeInterval) async throws -> Void
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var sleeping = false
    public private(set) var jobs: [WordNoteV2AnalysisJob] = []
    public private(set) var activeRecordID: UUID?
    public private(set) var activeAnalysisTitle: String?
    public private(set) var isSuspended: Bool
    public private(set) var statusMessage: String?
    public private(set) var errorMessage: String?
    public var latestAIExplanation: AIExplanationPreview?
    public let feedback = CaptureFeedbackHub()

    public convenience init(
        session: WordNoteStoreSession, store: WordNoteRestoreStore,
        analysisHandler: @escaping AnalysisHandler
    ) throws {
        guard session.schemaVersion == .v2 else { throw WordNoteV2ContentError.wrongSchema }
        try self.init(
            content: WordNoteV2ContentService(container: session.container),
            initiallySuspended: session.analysisRequiresResume, analysisHandler: analysisHandler,
            persistPause: { try store.requireAnalysisPause(for: session.generation) },
            authorizeResume: { try store.authorizeAnalysisResume(for: session.generation) },
            validateSelection: {
                guard try !store.hasPreparedRestore(for: session.generation) else { throw WordNoteRestoreError.restoreAlreadyPending }
            }
        )
    }

    init(
        content: WordNoteV2ContentService, initiallySuspended: Bool = false,
        analysisHandler: @escaping AnalysisHandler,
        persistPause: @escaping @MainActor () throws -> Void,
        authorizeResume: @escaping @MainActor () throws -> Void,
        validateSelection: @escaping @MainActor () throws -> Void,
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @MainActor (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) throws {
        self.content = content
        self.analyze = analysisHandler
        self.persistPause = persistPause
        self.authorizeResume = authorizeResume
        self.validateSelection = validateSelection
        self.now = now
        self.sleep = sleep
        isSuspended = initiallySuspended
        jobs = try content.analysisJobs()
    }

    public var queuedCount: Int { jobs.filter { $0.state == .queued }.count }
    public var failedCount: Int { jobs.filter { $0.state == .failed }.count }
    public var isBusy: Bool { !isSuspended && (activeRecordID != nil || queuedCount > 0) }
    public var queueStatusText: String {
        if isSuspended { return "Analysis paused. Resume in Settings." }
        if let activeAnalysisTitle { return "Analyzing: \(activeAnalysisTitle)" }
        return sleeping ? "Waiting before retrying analysis..." : "Preparing AI analysis..."
    }

    @discardableResult
    public func enqueue(_ request: WordNoteCaptureRequest, analyze: Bool = true) throws -> WordNoteCaptureResult {
        try validateSelection()
        let result = try content.capture(request, analyze: analyze, at: now())
        errorMessage = nil
        switch result.destination {
        case .vocabulary(let id, _, _, _):
            let term = try content.term(id)
            let preview = AIExplanationPreview(
                rawText: request.rawText.trimmingCharacters(in: .whitespacesAndNewlines), sentenceMeaning: nil,
                candidates: [.init(id: id.uuidString, term: term.term, importance: term.importance,
                                   chineseMeaning: term.chineseMeaning, englishDefinition: term.englishDefinition,
                                   aiContextExplanation: term.aiContextExplanation)]
            )
            latestAIExplanation = preview
            if !result.isReplay {
                feedback.publish(.init(
                    preview: preview, direction: request.intent.resolvedDirection(for: request.rawText),
                    target: .vocabulary(id), captureID: request.captureID, capturedVia: request.capturedVia
                ))
            }
            statusMessage = "Found in vocabulary. Added to today's review."
        case .inputRecord(_, let state):
            statusMessage = state == .queued ? "Saved to the analysis queue." : "Saved."
        }
        try refreshJobs()
        wakeWorker()
        return result
    }

    public func retry(_ id: UUID, expectedRevision: Int) throws {
        try validateSelection()
        _ = try content.queueAnalysis(id, expectedRevision: expectedRevision, at: now())
        try refreshJobs()
        errorMessage = nil
        wakeWorker()
    }

    public func cancel(_ id: UUID, expectedRevision: Int) throws {
        try validateSelection()
        try content.cancelAnalysis(id, expectedRevision: expectedRevision, at: now())
        if activeRecordID == id { invalidateWorker() }
        try refreshJobs()
        wakeWorker()
    }

    @discardableResult
    public func recoverPendingAnalyses() throws -> Int {
        try validateSelection()
        try refreshJobs()
        if activeRecordID == nil, jobs.contains(where: { $0.state == .running }) {
            isSuspended = true
            invalidateWorker()
            // Persist this before normalizing running -> queued, including across a second crash.
            try persistPause()
            _ = try content.recoverInterruptedAnalyses(at: now())
            try refreshJobs()
            statusMessage = "Interrupted analysis is paused. Resume explicitly in Settings."
        }
        wakeWorker()
        return queuedCount
    }

    public func pause() throws {
        try validateSelection()
        try persistPause()
        suspendForRestore()
    }

    /// The restore coordinator persists the pause before blocking writes and calling this.
    public func suspendForRestore() {
        isSuspended = true
        invalidateWorker()
        latestAIExplanation = nil
        feedback.clear()
    }

    @discardableResult
    public func resumePendingAnalyses() throws -> Int {
        guard isSuspended else { return try recoverPendingAnalyses() }
        try validateSelection()
        try persistPause()
        _ = try content.recoverInterruptedAnalyses(at: now())
        try refreshJobs()
        try authorizeResume()
        isSuspended = false
        errorMessage = nil
        wakeWorker()
        return queuedCount
    }

    public func refreshJobs() throws { jobs = try content.analysisJobs() }

    private func wakeWorker() {
        guard !isSuspended else { return }
        if sleeping { invalidateWorker() }
        guard worker == nil, jobs.contains(where: { $0.state == .queued || $0.state == .running }) else { return }
        let runID = UUID()
        epoch = runID
        worker = Task { @MainActor in await run(runID) }
    }

    private func invalidateWorker() {
        epoch = UUID()
        worker?.cancel()
        worker = nil
        sleeping = false
        activeRecordID = nil
        activeAnalysisTitle = nil
    }

    private func run(_ runID: UUID) async {
        defer {
            if epoch == runID {
                worker = nil
                sleeping = false
                activeRecordID = nil
                activeAnalysisTitle = nil
            }
        }
        while epoch == runID, !Task.isCancelled, !isSuspended {
            do {
                try validateSelection()
                try refreshJobs()
                if jobs.contains(where: { $0.state == .running }) {
                    _ = try recoverPendingAnalyses()
                    return
                }
                let currentTime = now()
                let queued = jobs.filter { $0.state == .queued }
                guard let job = queued.first(where: { $0.nextAttemptAt.map { $0 <= currentTime } ?? true }) else {
                    guard let next = queued.compactMap(\.nextAttemptAt).min() else { return }
                    sleeping = true
                    // Wake periodically after wall-clock changes; new captures wake this immediately.
                    try await sleep(min(60, max(0.01, next.timeIntervalSince(currentTime))))
                    guard epoch == runID, !Task.isCancelled else { return }
                    sleeping = false
                    continue
                }
                let attempt = try content.beginAnalysis(job.id, expectedRevision: job.revision, at: currentTime)
                activeRecordID = job.id
                activeAnalysisTitle = job.rawText
                try refreshJobs()
                let result: AIAnalysisResult
                do { result = try await analyze(attempt.request) }
                catch {
                    guard epoch == runID, !Task.isCancelled else { return }
                    try recordFailure(error, attempt: attempt)
                    activeRecordID = nil
                    activeAnalysisTitle = nil
                    continue
                }
                guard epoch == runID, !Task.isCancelled else { return }
                try validateSelection()
                do {
                    let preview = try content.completeAnalysis(attempt, result: result, at: now())
                    latestAIExplanation = preview
                    feedback.publish(.init(
                        preview: preview, direction: attempt.request.lookupDirection, target: .inputRecord(attempt.recordID),
                        captureID: attempt.captureID, capturedVia: attempt.capturedVia
                    ))
                    statusMessage = "Analysis is ready in Inbox."
                    errorMessage = nil
                } catch let error as AIAnalysisError {
                    try recordFailure(error, attempt: attempt)
                } catch WordNoteV2AnalysisError.staleAttempt {
                    // Deletion, cancellation or a newer revision wins over a delayed response.
                }
                activeRecordID = nil
                activeAnalysisTitle = nil
            } catch {
                guard epoch == runID, !Task.isCancelled else { return }
                stopAfterStorageFailure()
                return
            }
        }
    }

    private func recordFailure(_ error: Error, attempt: WordNoteV2AnalysisAttempt) throws {
        try validateSelection()
        do {
            if error is CancellationError {
                try content.cancelAnalysis(attempt.recordID, expectedRevision: attempt.revision, at: now())
            } else {
                try content.failAnalysis(attempt, error: error, at: now())
            }
        } catch WordNoteV2AnalysisError.staleAttempt { return }
        try refreshJobs()
        errorMessage = jobs.first { $0.id == attempt.recordID }?.errorSummary
    }

    private func stopAfterStorageFailure() {
        suspendForRestore()
        statusMessage = nil
        do {
            try persistPause()
            errorMessage = "Analysis paused because the data session changed or a result could not be saved. Check storage before resuming."
        } catch {
            errorMessage = "Analysis stopped. The pause could not be saved; check storage and reopen Word Note before resuming."
        }
        try? refreshJobs()
    }
}
