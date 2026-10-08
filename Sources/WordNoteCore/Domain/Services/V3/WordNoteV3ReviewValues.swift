import Foundation

public enum WordNoteV3ReviewError: LocalizedError, Equatable {
    case noActivePresentedItem, ownershipConflict, invalidLease, answerNotRevealed
    case stalePreview, invalidPreview, actionConflict, invalidatedAction
    case activeSessionExists(UUID), noEligibleCards, sessionPaused, newCardLimitReached
    case controlRecordLimit

    public var errorDescription: String? {
        switch self {
        case .noActivePresentedItem: "There is no presented card to answer in this session."
        case .ownershipConflict: "Another window owns this review session. Continue there or release it first."
        case .invalidLease: "This window no longer owns the review session. Resume it before answering."
        case .answerNotRevealed: "Reveal the current answer before giving feedback."
        case .stalePreview: "This card, session, or study day changed. Refresh and reveal the answer again."
        case .invalidPreview: "The feedback preview does not match the scheduling rules. No answer was saved."
        case .actionConflict: "This action identifier was already used for a different review operation."
        case .invalidatedAction: "This saved answer was invalidated and cannot be replayed as a successful action."
        case .activeSessionExists: "Continue or end the existing review session before starting another."
        case .noEligibleCards: "There are no available cards in this scope."
        case .sessionPaused: "Resume this session before presenting a card."
        case .newCardLimitReached: "The daily new-card limit has been reached. No new card was introduced."
        case .controlRecordLimit: "This session has reached its action limit. End it and start a new group."
        }
    }
}

public struct WordNoteV3ReviewSessionSnapshot: Equatable, Sendable {
    public let session: WordNoteSnapshotV3Payload.Session
    public let items: [WordNoteSnapshotV3Payload.SessionItem]
}

public struct WordNoteV3ReviewLease: Equatable, Sendable {
    public let sessionID: UUID
    public let ownerID: UUID
    let id: UUID
    let writeTicket: WordNoteWriteGate.Ticket
}

public struct WordNoteV3ReviewAnswerSnapshot: Codable, Equatable, Sendable {
    public let session: WordNoteSnapshotV3Payload.Session
    public let item: WordNoteSnapshotV3Payload.SessionItem
    public let card: WordNoteSnapshotV3Payload.Card
    public let term: WordNoteSnapshotPayload.Term
    public let termState: WordNoteSnapshotV2Payload.TermState
}

public struct WordNoteV3FeedbackPreview: Equatable, Sendable {
    public let source: WordNoteV3ReviewAnswerSnapshot
    public let plan: ReviewCardFeedbackPlan
    let leaseID: UUID
}

public struct WordNoteV3FeedbackReceipt: Equatable, Sendable {
    public let eventID: UUID
    public let actionID: UUID
    public let sessionID: UUID
    public let originalCardID: UUID
    public let feedback: ReviewFeedback
    public let before: ReviewCardSchedule
    public let after: ReviewCardSchedule
    public let reviewedAt: Date
    public let clockAnomaly: ReviewClockAnomaly?
    public let disposition: ReviewFeedbackDisposition
    public let isReplay: Bool
}
