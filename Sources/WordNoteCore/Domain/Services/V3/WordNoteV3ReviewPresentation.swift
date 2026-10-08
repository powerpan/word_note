import Foundation

extension WordNoteV3ReviewService {
    /// Nil means this fixed group has no relearning card ready yet. It does not create or extend a group.
    public func presentNextCard(lease: WordNoteV3ReviewLease, expectedRevision: Int,
                                at date: Date = Date()) throws -> WordNoteV3ReviewAnswerSnapshot? {
        try content.transaction {
            _ = try WordNoteV3ReviewOwnership.require(lease, in: context)
            try content.validateDate(date)
            let session = try session(lease.sessionID)
            try content.requireRevision(session.revision, expectedRevision)
            let snapshot = try sessionSnapshot(session.id)
            guard snapshot.session.status != .paused else { throw WordNoteV3ReviewError.sessionPaused }
            guard snapshot.session.status.isResumable else { throw WordNoteV3ReviewError.noActivePresentedItem }
            if snapshot.items.contains(where: { $0.id == session.currentItemID && $0.status == .presented }) {
                return try currentSnapshot(sessionID: session.id)
            }
            let ready = try snapshot.items.filter { item in
                guard item.status == .waiting, let id = item.cardID, (item.availableAt ?? .distantFuture) <= date else { return false }
                let card = try Payload.Card(card(id))
                return try ReviewCardQueuePolicy().availability(of: card.schedule, at: date,
                    studyTimeZoneID: snapshot.session.scope.studyTimeZoneID, lastInteractionAt: card.updatedAt) == .relearningDue
            }
                .sorted { ($0.availableAt ?? .distantFuture, $0.position) < ($1.availableAt ?? .distantFuture, $1.position) }
            guard let selected = ready.first ?? snapshot.items.first(where: { $0.status == .pending || $0.status == .presented }),
                  let cardID = selected.cardID else { return nil }
            let card = try card(cardID)
            let before = try Payload.Card(card)
            if selected.status != .presented {
                let availability = try ReviewCardQueuePolicy().availability(of: before.schedule, at: date,
                    studyTimeZoneID: snapshot.session.scope.studyTimeZoneID, lastInteractionAt: card.updatedAt)
                guard availability != .notDue else { throw WordNoteV3ReviewError.stalePreview }
                if before.schedule.phase == .new, before.schedule.introducedAt == nil, !snapshot.session.scope.includesNewCards {
                    throw WordNoteV3ReviewError.noEligibleCards
                }
                let plan = try scheduler.presentation(for: before.schedule, at: date,
                    studyTimeZoneID: snapshot.session.scope.studyTimeZoneID, lastInteractionAt: card.updatedAt)
                if before.schedule.phase == .new, before.schedule.introducedAt == nil {
                    let quota = try ReviewNewCardQuota(payload: Payload.capture(from: context), limit: session.newCardLimitSnapshot,
                        at: date, timeZoneID: snapshot.session.scope.studyTimeZoneID)
                    guard quota.remaining > 0 else { throw WordNoteV3ReviewError.newCardLimitReached }
                    var introductions = snapshot.session.introductions ?? []
                    introductions.append(quota.introduction(cardID: cardID))
                    session.introductionsJSON = try ReviewPersistenceJSON.encode(introductions)
                }
                plan.after.apply(to: card)
                card.revision = try content.increment(card.revision)
                card.updatedAt = max(card.updatedAt, plan.clock.effectiveAt)
                // Legacy due dates stay intact until feedback, but presentation now has current semantics.
                card.schedulerVersion = ReviewSchedulerVersion.current
            }
            guard let item = try content.fetch(Item.self).first(where: { $0.id == selected.id }) else { throw WordNoteV3ContentError.missingEntity }
            item.statusRaw = ReviewSessionItemStatus.presented.rawValue
            item.availableAt = nil
            item.updatedAt = max(item.updatedAt, date)
            session.currentItemID = item.id
            session.statusRaw = ReviewSessionStatus.active.rawValue
            session.revision = try content.increment(session.revision)
            session.updatedAt = max(session.updatedAt, date)
            return try currentSnapshot(sessionID: session.id)
        }
    }
}
