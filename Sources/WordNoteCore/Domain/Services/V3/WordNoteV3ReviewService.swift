import Foundation
import SwiftData

/// The sole V3 answer writer. Session creation and first presentation are separate operations.
@MainActor
public final class WordNoteV3ReviewService {
    typealias Payload = WordNoteSnapshotV3Payload
    typealias Card = WordNoteSchemaV3.ReviewCardModel
    typealias Session = WordNoteSchemaV3.ReviewSessionModel
    typealias Item = WordNoteSchemaV3.ReviewSessionItemModel
    typealias Event = WordNoteSchemaV3.ReviewEventModel

    let content: WordNoteV3ContentService
    let scheduler = ReviewCardScheduler()
    var context: ModelContext { content.context }

    public convenience init(container: ModelContainer) throws {
        try self.init(container: container, beforeSave: { _ in })
    }

    init(container: ModelContainer, beforeSave: @escaping @MainActor (ModelContext) throws -> Void) throws {
        content = try WordNoteV3ContentService(container: container, beforeSave: beforeSave)
    }

    public func acquireLease(sessionID: UUID, ownerID: UUID) throws -> WordNoteV3ReviewLease {
        try content.transaction {
            guard try Payload.Session(session(sessionID)).status.isResumable else { throw WordNoteV3ReviewError.noActivePresentedItem }
            return try WordNoteV3ReviewOwnership.acquire(sessionID: sessionID, ownerID: ownerID, in: context)
        }
    }

    public func releaseLease(_ lease: WordNoteV3ReviewLease) {
        WordNoteV3ReviewOwnership.release(lease, in: context)
    }

    public func currentAnswerSnapshot(sessionID: UUID) throws -> WordNoteV3ReviewAnswerSnapshot {
        try content.transaction { try currentSnapshot(sessionID: sessionID) }
    }

    public func previewFeedback(_ feedback: ReviewFeedback, lease: WordNoteV3ReviewLease,
                                at date: Date = Date()) throws -> WordNoteV3FeedbackPreview {
        try content.transaction {
            let owner = try WordNoteV3ReviewOwnership.require(lease, in: context)
            let source = try currentSnapshot(sessionID: lease.sessionID)
            guard owner.revealed == source else { throw WordNoteV3ReviewError.answerNotRevealed }
            return try .init(source: source, plan: plan(feedback, source: source, at: date), leaseID: lease.id)
        }
    }

    public func feedbackReceipt(actionID: UUID) throws -> WordNoteV3FeedbackReceipt? {
        try content.transaction {
            try content.fetch(Event.self, matching: \.actionID, in: [actionID]).first.map { try receipt($0, replay: true) }
        }
    }

    func currentSnapshot(sessionID: UUID) throws -> WordNoteV3ReviewAnswerSnapshot {
        let session = try Payload.Session(session(sessionID))
        guard session.status == .active, let itemID = session.currentItemID,
              session.controls?.skippedItemIDs.contains(itemID) != true,
              let item = try content.fetch(Item.self, matching: \.id, in: [itemID]).first,
              item.sessionID == sessionID, item.statusRaw == ReviewSessionItemStatus.presented.rawValue,
              let cardID = item.cardID else { throw WordNoteV3ReviewError.noActivePresentedItem }
        let card = try Payload.Card(card(cardID))
        let term = try content.term(card.termID)
        return try .init(session: session, item: Payload.SessionItem(item), card: card,
            term: WordNoteSnapshotPayload.Term(term), termState: WordNoteSnapshotV2Payload.TermState(term))
    }

    func session(_ id: UUID) throws -> Session {
        guard let session = try content.fetch(Session.self, matching: \.id, in: [id]).first else { throw WordNoteV3ContentError.missingEntity }
        return session
    }

    func card(_ id: UUID) throws -> Card {
        guard let card = try content.fetch(Card.self, matching: \.id, in: [id]).first else { throw WordNoteV3ContentError.missingEntity }
        return card
    }

    func plan(_ feedback: ReviewFeedback, source: WordNoteV3ReviewAnswerSnapshot, at date: Date) throws -> ReviewCardFeedbackPlan {
        try scheduler.feedback(feedback, for: source.card.schedule, at: date,
            studyTimeZoneID: source.session.scope.studyTimeZoneID, lastInteractionAt: source.card.updatedAt)
    }

    func receipt(_ event: Event, replay: Bool) throws -> WordNoteV3FeedbackReceipt {
        let state = try Payload.EventState(event)
        guard state.invalidatedAt == nil else { throw WordNoteV3ReviewError.invalidatedAction }
        guard state.feedbackSemanticsVersion == 2, let actionID = state.actionID,
              let sessionID = state.sessionID, let cardID = state.originalCardID,
              let before = state.beforeSchedule, let after = state.afterSchedule else { throw WordNoteV3ContentError.invalidState }
        let feedback: ReviewFeedback = try snapshotEnum(event.feedbackRaw)
        let disposition: ReviewFeedbackDisposition
        if after.phase == .relearning { disposition = .relearning }
        else if feedback == .again || (feedback == .hard && before.phase == .relearning) { disposition = .relearningLimitReached }
        else { disposition = .reviewed }
        return .init(eventID: event.id, actionID: actionID, sessionID: sessionID, originalCardID: cardID,
            feedback: feedback, before: before, after: after, reviewedAt: event.reviewedAt,
            clockAnomaly: state.clockAnomaly, disposition: disposition, isReplay: replay)
    }
}
