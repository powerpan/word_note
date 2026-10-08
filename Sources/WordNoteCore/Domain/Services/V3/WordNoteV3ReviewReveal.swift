import Foundation

extension WordNoteV3ReviewService {
    public func revealAnswer(_ expected: WordNoteV3ReviewAnswerSnapshot, lease: WordNoteV3ReviewLease,
                             at date: Date = Date()) throws -> WordNoteV3ReviewAnswerSnapshot {
        let owner = try WordNoteV3ReviewOwnership.require(lease, in: context)
        let revealed = try content.transaction {
            try content.validateDate(date)
            let source = try currentSnapshot(sessionID: lease.sessionID)
            guard source == expected else { throw WordNoteV3ReviewError.stalePreview }
            _ = try questionFront(card: source.card, term: source.term)
            if owner.revealed == source { return source }
            let clock = try source.card.schedule.studyClock(at: date, timeZoneID: source.session.scope.studyTimeZoneID,
                lastInteractionAt: source.card.updatedAt)
            guard source.card.schedule.phase != .suspended else { throw ReviewCardSchedulingError.suspended }
            if let until = source.card.schedule.buriedUntil, until > date { throw ReviewCardSchedulingError.buried }
            let until = try clock.nextDayStart
            let term = try content.term(source.card.termID)
            term.reviewExposedUntil = max(term.reviewExposedUntil ?? until, until)
            var siblingIDs = Set<UUID>()
            for sibling in try content.fetch(Card.self, matching: \.termID, in: [source.card.termID])
                where sibling.id != source.card.id && sibling.phaseRaw != ReviewCardPhase.suspended.rawValue {
                siblingIDs.insert(sibling.id)
                if (sibling.buriedUntil ?? .distantPast) < until {
                    sibling.buriedUntil = until
                    sibling.revision = try content.increment(sibling.revision)
                    sibling.updatedAt = max(sibling.updatedAt, clock.effectiveAt)
                }
            }
            var changedItems = false
            for item in try content.fetch(Item.self, matching: \.sessionID, in: [source.session.id]) {
                let status: ReviewSessionItemStatus = try snapshotEnum(item.statusRaw)
                guard !status.isTerminal, let cardID = item.cardID, siblingIDs.contains(cardID) else { continue }
                item.statusRaw = ReviewSessionItemStatus.siblingDeferred.rawValue
                item.completionOutcomeRaw = ReviewCompletionOutcome.siblingDeferred.rawValue
                item.availableAt = nil
                item.updatedAt = max(item.updatedAt, clock.effectiveAt)
                changedItems = true
            }
            if changedItems {
                let session = try session(source.session.id)
                session.revision = try content.increment(session.revision)
                session.updatedAt = max(session.updatedAt, clock.effectiveAt)
            }
            let current = try card(source.card.id)
            current.revision = try content.increment(current.revision)
            current.updatedAt = max(current.updatedAt, clock.effectiveAt)
            return try currentSnapshot(sessionID: lease.sessionID)
        }
        // A failed save must leave the answer unrevealed and retain the original retry capability.
        owner.revealed = revealed
        return revealed
    }
}
