import Foundation

extension WordNoteV3ContentService {
    /// Explicit opt-in; never copies a sibling direction's ability or introduction history.
    public func enableReviewDirection(termID: UUID, expectedTermRevision: Int, mode: ReviewMode,
                                      studyTimeZoneID: String, at date: Date = Date()) throws -> WordNoteSnapshotV3Payload.Card {
        try transaction {
            try validateDate(date)
            guard mode != .contextCloze else { throw WordNoteV3ContentError.invalidValue }
            let term = try term(termID)
            try requireRevision(term.revision, expectedTermRevision)
            let existing = try fetch(Card.self).first { $0.termID == termID && $0.modeRaw == mode.rawValue }
            let model = existing ?? Card(termID: termID, mode: mode, createdAt: max(date, term.updatedAt))
            var card = try WordNoteSnapshotV3Payload.Card(model)
            if card.schedule.phase == .suspended {
                let unlearned = card.schedulerVersion == ReviewSchedulerVersion.current && card.schedule.introducedAt == nil
                    && card.schedule.lastReviewedAt == nil && card.schedule.masteryLevel == .new && card.schedule.intervalDays == 0
                card.schedule.phase = unlearned ? .new : .review
                card.schedule.nextReviewAt = card.schedule.phase == .new ? nil : max(date, model.updatedAt)
            }
            _ = try ReviewQuestionContent.front(card: card, term: .init(term))
            let burial = try reviewDirectionBurial(termID: termID, at: date, studyTimeZoneID: studyTimeZoneID)
            if existing != nil, model.phaseRaw != ReviewCardPhase.suspended.rawValue { return try .init(model) }
            card.schedule.buriedUntil = burial
            card.schedule.apply(to: model)
            if existing == nil { context.insert(model) }
            else { model.revision = try increment(model.revision) }
            model.updatedAt = max(model.updatedAt, date)
            try touch(term, at: max(term.updatedAt, date))
            return try .init(model)
        }
    }

    func reviewDirectionBurial(termID: UUID, at date: Date, studyTimeZoneID: String) throws -> Date? {
        let siblings = try fetch(Card.self).filter { $0.termID == termID }
        let ids = Set(siblings.map(\.id))
        let items = try fetch(SessionItem.self).filter { ids.contains($0.originalCardID) }
        let events = try fetch(ReviewEvent.self).filter {
            $0.termID == termID && $0.feedbackSemanticsVersion == 2 && $0.invalidatedAt == nil
        }
        let floor = (siblings.map(\.updatedAt) + items.map(\.updatedAt) + events.map(\.reviewedAt)).max()
        let clock = try ReviewStudyClock(at: date, timeZoneID: studyTimeZoneID, notBefore: floor)
        let day = try ReviewStudyDay(containing: clock.effectiveAt, timeZoneID: studyTimeZoneID)
        let exposedUntil = try term(termID).reviewExposedUntil
        var burial = (siblings.compactMap(\.buriedUntil) + [exposedUntil].compactMap { $0 }).filter { $0 > date }.max()
        // Presentation is durable; reveal ownership is not. Conservatively treat a presented sibling as exposed.
        let exposureStates = Set([ReviewSessionItemStatus.presented, .waiting, .completed, .postponed, .siblingDeferred].map(\.rawValue))
        let exposed = items.contains { exposureStates.contains($0.statusRaw) && $0.updatedAt >= day.start }
            || events.contains { $0.reviewedAt >= day.start }
        if exposed { burial = max(burial ?? day.end, day.end) }
        return burial
    }
}
