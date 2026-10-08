import Foundation
import SwiftData

extension WordNoteV3ReviewService {
    public func recordFeedback(_ preview: WordNoteV3FeedbackPreview, actionID: UUID,
                               lease: WordNoteV3ReviewLease, at date: Date = Date()) throws -> WordNoteV3FeedbackReceipt {
        let result: (receipt: WordNoteV3FeedbackReceipt, ended: Bool) = try content.transaction {
            if let existing = try content.fetch(Event.self, matching: \.actionID, in: [actionID]).first {
                let saved = try receipt(existing, replay: true)
                guard saved.sessionID == preview.source.session.id, saved.originalCardID == preview.source.card.id,
                      existing.termID == preview.source.term.id, existing.modeRaw == preview.source.card.mode.rawValue,
                      saved.feedback == preview.plan.feedback, saved.before == preview.source.card.schedule else {
                    throw WordNoteV3ReviewError.actionConflict
                }
                return (saved, false)
            }
            guard try savedControl(actionID: actionID) == nil else { throw WordNoteV3ReviewError.actionConflict }
            let owner = try WordNoteV3ReviewOwnership.require(lease, in: context)
            guard preview.leaseID == lease.id, preview.source.session.id == lease.sessionID else { throw WordNoteV3ReviewError.invalidLease }
            let current = try currentSnapshot(sessionID: lease.sessionID)
            guard current == preview.source else { throw WordNoteV3ReviewError.stalePreview }
            guard owner.revealed == current else { throw WordNoteV3ReviewError.answerNotRevealed }
            let originalPlan = try plan(preview.plan.feedback, source: current, at: preview.plan.clock.observedAt)
            guard originalPlan == preview.plan else { throw WordNoteV3ReviewError.invalidPreview }
            let actual = try plan(preview.plan.feedback, source: current, at: date)
            try requireEquivalentPreview(preview.plan, actual)

            let event = Event(termID: current.term.id, mode: current.card.mode, feedback: actual.feedback,
                previousMasteryLevel: actual.before.masteryLevel, newMasteryLevel: actual.after.masteryLevel,
                previousNextReviewAt: actual.before.nextReviewAt, newNextReviewAt: actual.after.nextReviewAt, reviewedAt: actual.clock.observedAt)
            try Payload.EventState(id: event.id, cardID: current.card.id, originalCardID: current.card.id,
                sessionID: current.session.id, actionID: actionID, feedbackSemanticsVersion: 2,
                schedulerVersion: ReviewSchedulerVersion.current, studyDayKey: actual.clock.studyDayKey,
                studyTimeZoneID: actual.clock.studyTimeZoneID, beforeSchedule: actual.before, afterSchedule: actual.after,
                clockAnomaly: actual.clock.anomaly, invalidatedAt: nil,
                recordedOrder: content.increment(latestRecordedOrder())).apply(to: event)
            context.insert(event)

            let card = try card(current.card.id)
            actual.after.apply(to: card)
            card.schedulerVersion = ReviewSchedulerVersion.current
            card.revision = try content.increment(card.revision)
            card.updatedAt = max(card.updatedAt, actual.clock.effectiveAt)
            guard let item = try content.fetch(Item.self, matching: \.id, in: [current.item.id]).first else { throw WordNoteV3ContentError.missingEntity }
            item.attemptCount = try content.increment(item.attemptCount)
            item.lastActionID = actionID
            item.updatedAt = max(item.updatedAt, actual.clock.effectiveAt)
            switch actual.disposition {
            case .relearning:
                item.statusRaw = ReviewSessionItemStatus.waiting.rawValue
                item.availableAt = actual.after.nextReviewAt
                item.completionOutcomeRaw = nil
            case .reviewed:
                item.statusRaw = ReviewSessionItemStatus.completed.rawValue
                item.availableAt = nil
                item.completionOutcomeRaw = ReviewCompletionOutcome.reviewed.rawValue
            case .relearningLimitReached:
                item.statusRaw = ReviewSessionItemStatus.postponed.rawValue
                item.availableAt = nil
                item.completionOutcomeRaw = ReviewCompletionOutcome.postponed.rawValue
            }
            let session = try session(current.session.id)
            try resetSkipRound(in: session)
            try advanceCursor(in: session, at: actual.clock.effectiveAt)
            return try (receipt(event, replay: false), !Payload.Session(session).status.isResumable)
        }
        if !result.receipt.isReplay {
            WordNoteV3ReviewOwnership.didSaveAnswer(lease, ended: result.ended, in: context)
        }
        return result.receipt
    }

    private func requireEquivalentPreview(_ shown: ReviewCardFeedbackPlan, _ actual: ReviewCardFeedbackPlan) throws {
        var shownState = shown.after, actualState = actual.after
        shownState.nextReviewAt = nil
        actualState.nextReviewAt = nil
        shownState.lastReviewedAt = nil
        actualState.lastReviewedAt = nil
        guard actual.clock.observedAt >= shown.clock.observedAt,
              actual.clock.studyDayKey == shown.clock.studyDayKey, actual.clock.anomaly == shown.clock.anomaly,
              actual.delay == shown.delay, actual.disposition == shown.disposition, shownState == actualState else {
            throw WordNoteV3ReviewError.stalePreview
        }
    }

    private func latestRecordedOrder() throws -> Int {
        var descriptor = FetchDescriptor<Event>(sortBy: [SortDescriptor(\.recordedOrder, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.recordedOrder ?? 0
    }

    func advanceCursor(in session: Session, at date: Date) throws {
        let items = try content.fetch(Item.self, matching: \.sessionID, in: [session.id]).map { try Payload.SessionItem($0) }
        let remaining = items.filter { !$0.status.isTerminal }.sorted { ($0.position, $0.id.uuidString) < ($1.position, $1.id.uuidString) }
        if let next = remaining.first(where: { $0.status == .pending || $0.status == .presented }) {
            session.currentItemID = next.id
            session.statusRaw = ReviewSessionStatus.active.rawValue
        } else if !remaining.isEmpty {
            session.currentItemID = nil
            session.statusRaw = ReviewSessionStatus.waiting.rawValue
        } else {
            session.currentItemID = nil
            session.statusRaw = ReviewSessionStatus.completed.rawValue
            session.endedAt = date
        }
        session.revision = try content.increment(session.revision)
        session.updatedAt = max(session.updatedAt, date)
    }
}
