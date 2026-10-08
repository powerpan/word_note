import Foundation
import Observation
import SwiftData
import WordNoteCore

/// One controller per Review surface. Persistent session state belongs to the service,
/// while answer visibility and the answering lease belong to this window only.
@MainActor
@Observable
final class V3ReviewController {
    private let service: WordNoteV3ReviewService
    private let ownerID = UUID()
    private var lease: WordNoteV3ReviewLease?
    private var answerSnapshot: WordNoteV3ReviewAnswerSnapshot?
    private var previews: [ReviewFeedback: WordNoteV3FeedbackPreview] = [:]
    private var actionIDs: [ReviewFeedback: UUID] = [:]
    private(set) var session: WordNoteV3ReviewSessionSnapshot?
    private(set) var statistics: ReviewSessionStatistics?
    private(set) var front: ReviewQuestionFront?
    private(set) var back: ReviewQuestionBack?
    private(set) var errorMessage: String?
    private(set) var isWindowActive = false
    private(set) var isAvailable = true
    var typedAnswer = ""

    var ownsSession: Bool { lease != nil && isWindowActive && isAvailable }
    var canReveal: Bool { ownsSession && front != nil && back == nil }
    var canAnswer: Bool { ownsSession && back != nil && previews.count == ReviewFeedback.allCases.count }

    init(container: ModelContainer) throws { service = try WordNoteV3ReviewService(container: container) }

    func load(at date: Date = Date()) {
        perform {
            if let current = session { session = try service.reviewSession(current.session.id) }
            else { session = try service.resumableSession() }
            try updateStatistics(at: date)
        }
    }

    func setWindowActive(_ active: Bool) {
        isWindowActive = active
        if !active { release() }
    }

    func setAvailable(_ available: Bool) {
        isAvailable = available
        if !available { release() }
    }

    func release() {
        if let lease { service.releaseLease(lease) }
        lease = nil
        clearQuestion()
    }

    func start(scope: ReviewSessionScopeSnapshot, target: Int, newLimit: Int, at date: Date = Date()) {
        guard isWindowActive, isAvailable else { return }
        perform {
            release()
            session = try service.startSession(scope: scope, targetCardCount: target, newCardLimit: newLimit, at: date)
            try acquireAndPresent(at: date)
        }
    }

    func resume(at date: Date = Date()) {
        guard isWindowActive, isAvailable else { return }
        perform {
            session = try service.resumableSession()
            guard session != nil else { clearQuestion(); statistics = nil; return }
            try acquireAndPresent(at: date)
        }
    }

    func reveal(at date: Date = Date()) {
        guard canReveal, let lease, let answerSnapshot else { return }
        perform {
            self.answerSnapshot = try service.revealAnswer(answerSnapshot, lease: lease, at: date)
            let revealed = try service.revealedQuestion(lease: lease, typedAnswer: typedAnswer)
            var next: [ReviewFeedback: WordNoteV3FeedbackPreview] = [:]
            for feedback in ReviewFeedback.allCases { next[feedback] = try service.previewFeedback(feedback, lease: lease, at: date) }
            previews = next
            actionIDs = Dictionary(uniqueKeysWithValues: ReviewFeedback.allCases.map { ($0, UUID()) })
            back = revealed
            session = try service.reviewSession(lease.sessionID)
            try updateStatistics(at: date)
        }
    }

    func delay(for feedback: ReviewFeedback) -> String {
        guard let plan = previews[feedback]?.plan else { return "" }
        let value: String
        switch plan.delay {
        case .minutes(let count): value = AppLocalization.format("%lld min", count)
        case .calendarDays(let count): value = AppLocalization.format(count == 1 ? "%lld day" : "%lld days", count)
        }
        return plan.disposition == .relearningLimitReached ? AppLocalization.format("%@, daily limit", value) : value
    }

    func answer(_ feedback: ReviewFeedback, at date: Date = Date()) {
        guard canAnswer, let lease, let preview = previews[feedback], let actionID = actionIDs[feedback] else { return }
        perform {
            _ = try service.recordFeedback(preview, actionID: actionID, lease: lease, at: date)
            try advance(at: date)
        }
    }

    func skip(at date: Date = Date()) { control(.skip, at: date) }
    func later(at date: Date = Date()) { control(.later, at: date) }

    func pause(at date: Date = Date()) {
        guard ownsSession, let lease, let session else { return }
        perform {
            self.session = try service.pauseSession(lease: lease, expectedRevision: session.session.revision, at: date)
            release()
            try updateStatistics(at: date)
        }
    }

    func end(at date: Date = Date()) {
        // A confirmation sheet temporarily takes key-window status from its host.
        // Ending is explicit and still requires the shared lease; it never records an answer.
        guard isAvailable, let session, session.session.status.isResumable else { return }
        perform {
            let current = try service.reviewSession(session.session.id)
            let lease = try service.acquireLease(sessionID: current.session.id, ownerID: ownerID)
            self.lease = lease
            self.session = try service.endSession(lease: lease, expectedRevision: current.session.revision, at: date)
            release()
            try updateStatistics(at: date)
        }
    }

    func showSetup() {
        guard session?.session.status.isResumable != true else { return }
        release()
        session = nil
        statistics = nil
        errorMessage = nil
    }

    func tick(at date: Date = Date()) {
        guard ownsSession, session?.session.status == .waiting else { return }
        perform { try advance(at: date) }
    }

    @discardableResult
    func handleKey(_ key: String, isRepeat: Bool, hasModifiers: Bool, isTextEditing: Bool) -> Bool {
        guard ownsSession, !isRepeat, !hasModifiers, !isTextEditing else { return false }
        if key == " ", canReveal { reveal(); return true }
        let feedback: [String: ReviewFeedback] = ["1": .again, "2": .hard, "3": .good, "4": .easy]
        if let value = feedback[key], canAnswer { answer(value); return true }
        return false
    }

    private func acquireAndPresent(at date: Date) throws {
        guard var session else { return }
        let acquired = try service.acquireLease(sessionID: session.session.id, ownerID: ownerID)
        lease = acquired
        if session.session.status == .paused {
            session = try service.resumeSession(lease: acquired, expectedRevision: session.session.revision, at: date)
            self.session = session
        }
        try advance(at: date)
    }

    private func advance(at date: Date) throws {
        clearQuestion()
        guard let lease else { return }
        session = try service.reviewSession(lease.sessionID)
        if let session, session.session.status.isResumable && session.session.status != .paused {
            answerSnapshot = try service.presentNextCard(lease: lease, expectedRevision: session.session.revision, at: date)
            if answerSnapshot != nil { front = try service.questionFront(sessionID: lease.sessionID) }
            self.session = try service.reviewSession(lease.sessionID)
        } else { release() }
        try updateStatistics(at: date)
    }

    private func control(_ kind: ReviewSessionControlKind, at date: Date) {
        guard ownsSession, let lease, let answerSnapshot else { return }
        perform {
            if kind == .skip { _ = try service.skip(answerSnapshot, actionID: UUID(), lease: lease, at: date) }
            else { _ = try service.later(answerSnapshot, actionID: UUID(), lease: lease, at: date) }
            try advance(at: date)
        }
    }

    private func updateStatistics(at date: Date) throws {
        statistics = try session.map { try service.sessionStatistics($0.session.id, at: date) }
    }

    private func clearQuestion() {
        front = nil
        back = nil
        answerSnapshot = nil
        typedAnswer = ""
        previews = [:]
        actionIDs = [:]
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); errorMessage = nil }
        catch {
            release()
            errorMessage = error.localizedDescription
            // Reload metadata only. A failed/stale operation never silently reveals a new answer.
            if let current = session {
                session = try? service.reviewSession(current.session.id)
                statistics = try? service.sessionStatistics(current.session.id)
            }
        }
    }
}
