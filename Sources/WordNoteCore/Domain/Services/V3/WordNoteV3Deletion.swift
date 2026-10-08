import Foundation

extension WordNoteV3ContentService {
    public func deleteInputRecord(_ id: UUID, expectedRevision: Int, at date: Date = Date()) throws {
        try transaction {
            try validateDate(date)
            guard let record = try fetch(Record.self).first(where: { $0.id == id }) else { throw WordNoteV3ContentError.missingEntity }
            try requireRevision(record.revision, expectedRevision)
            let occurrences = try fetch(Occurrence.self).filter { $0.sourceRecordID == id }
            let termIDs = Set(occurrences.map(\.termID))
            for term in try fetch(Term.self).filter({ $0.sourceRecordID == id || termIDs.contains($0.id) }) {
                if term.sourceRecordID == id { term.sourceRecordID = nil }
                try touch(term, at: date)
            }
            occurrences.forEach { $0.sourceRecordID = nil }
            try fetch(Candidate.self).filter { $0.inputRecordID == id }.forEach(context.delete)
            context.delete(record)
        }
    }

    public func deleteOccurrence(_ id: UUID, expectedTermRevision: Int, at date: Date = Date()) throws {
        try transaction {
            try validateDate(date)
            guard let occurrence = try fetch(Occurrence.self).first(where: { $0.id == id }) else { throw WordNoteV3ContentError.missingEntity }
            let term = try term(occurrence.termID)
            try requireRevision(term.revision, expectedTermRevision)
            var affectedCards = Set<UUID>()
            for card in try fetch(Card.self) where card.modeRaw == ReviewMode.contextCloze.rawValue {
                guard let json = card.clozeTargetJSON else { throw WordNoteV3ContentError.invalidValue }
                var target: ReviewClozeTarget = try ReviewPersistenceJSON.decode(json)
                guard target.sourceDeletedAt == nil, target.occurrenceID == id else { continue }
                target.sourceDeletedAt = date
                target.sourceHash = ""
                target.startCharacterOffset = 0
                target.characterCount = 0
                target.answer = ""
                target.acceptedAnswers = []
                card.clozeTargetJSON = try ReviewPersistenceJSON.encode(target)
                try suspend(card, at: date)
                affectedCards.insert(card.id)
            }
            try invalidateSessionItems(for: affectedCards, at: date)
            try fetch(LookupEvent.self).filter { $0.occurrenceID == id }.forEach { $0.occurrenceID = nil }
            context.delete(occurrence)
            try touch(term, at: date)
        }
    }

    public func deleteTerm(_ id: UUID, expectedRevision: Int, at date: Date = Date()) throws {
        try transaction {
            try validateDate(date)
            let term = try term(id)
            try requireRevision(term.revision, expectedRevision)
            for candidate in try fetch(Candidate.self).filter({ $0.savedTermID == id }) {
                candidate.savedTermID = nil
                candidate.savedLinkStateRaw = "targetDeleted"
                candidate.revision = try increment(candidate.revision)
                candidate.updatedAt = date
            }
            let cards = try fetch(Card.self).filter { $0.termID == id }
            try invalidateSessionItems(for: Set(cards.map(\.id)), at: date)
            cards.forEach(context.delete)
            try fetch(ReviewEvent.self).filter { $0.termID == id }.forEach(context.delete)
            try fetch(Occurrence.self).filter { $0.termID == id }.forEach(context.delete)
            try fetch(CourseLink.self).filter { $0.termID == id }.forEach(context.delete)
            try fetch(LookupEvent.self).filter { $0.termID == id }.forEach(context.delete)
            context.delete(term)
        }
    }

    public func courseUsage(_ id: UUID) throws -> WordNoteV3CourseUsage {
        guard try fetch(Course.self).contains(where: { $0.id == id }) else { throw WordNoteV3ContentError.missingEntity }
        return WordNoteV3CourseUsage(inputRecords: try fetch(Record.self).filter { $0.courseID == id }.count,
            memberships: try fetch(CourseLink.self).filter { $0.courseID == id }.count,
            occurrences: try fetch(Occurrence.self).filter { $0.courseID == id }.count)
    }

    public func deleteCourse(_ id: UUID, expectedRevision: Int, at date: Date = Date()) throws {
        try transaction {
            try validateDate(date)
            guard let course = try fetch(Course.self).first(where: { $0.id == id }) else { throw WordNoteV3ContentError.missingEntity }
            try requireRevision(course.revision, expectedRevision)
            let usage = try courseUsage(id)
            guard !usage.isInUse else { throw WordNoteV3ContentError.courseInUse(usage) }
            for term in try fetch(Term.self).filter({ $0.courseID == id }) {
                term.courseID = nil
                try touch(term, at: date)
            }
            context.delete(course)
        }
    }

    public func deleteReviewCard(_ id: UUID, expectedRevision: Int, at date: Date = Date()) throws {
        try transaction {
            try validateDate(date)
            guard let card = try fetch(Card.self).first(where: { $0.id == id }) else { throw WordNoteV3ContentError.missingEntity }
            try requireRevision(card.revision, expectedRevision)
            try invalidateSessionItems(for: [id], at: date)
            try fetch(ReviewEvent.self).filter { $0.cardID == id }.forEach { $0.cardID = nil }
            try touch(term(card.termID), at: date)
            context.delete(card)
        }
    }

    public func suspendReviewCard(_ id: UUID, expectedRevision: Int, at date: Date = Date()) throws {
        try transaction {
            try validateDate(date)
            guard let card = try fetch(Card.self).first(where: { $0.id == id }) else { throw WordNoteV3ContentError.missingEntity }
            try requireRevision(card.revision, expectedRevision)
            guard card.phaseRaw != ReviewCardPhase.suspended.rawValue else { return }
            try suspend(card, at: date)
            try invalidateSessionItems(for: [id], at: date)
            try touch(term(card.termID), at: date)
        }
    }

    private func suspend(_ card: Card, at date: Date) throws {
        card.phaseRaw = ReviewCardPhase.suspended.rawValue
        card.nextReviewAt = nil
        card.priorityRequestedAt = nil
        card.revision = try increment(card.revision)
        card.updatedAt = date
    }

    private func invalidateSessionItems(for cardIDs: Set<UUID>, at date: Date) throws {
        guard !cardIDs.isEmpty else { return }
        let items = try fetch(SessionItem.self)
        let affected = items.filter { $0.cardID.map(cardIDs.contains) == true }
        guard !affected.isEmpty else { return }
        for item in affected {
            item.cardID = nil
            item.statusRaw = ReviewSessionItemStatus.unavailable.rawValue
            item.completionOutcomeRaw = ReviewCompletionOutcome.unavailable.rawValue
            item.availableAt = nil
            item.updatedAt = date
        }
        let sessionIDs = Set(affected.map(\.sessionID))
        for session in try fetch(Session.self) where sessionIDs.contains(session.id) {
            let status: ReviewSessionStatus = try snapshotEnum(session.statusRaw)
            if status.isResumable {
                let remaining = try items.filter { $0.sessionID == session.id }.filter {
                    let state: ReviewSessionItemStatus = try snapshotEnum($0.statusRaw)
                    return !state.isTerminal
                }
                if remaining.isEmpty {
                    session.statusRaw = ReviewSessionStatus.completed.rawValue
                    session.currentItemID = nil
                    session.endedAt = date
                } else if !remaining.contains(where: { $0.id == session.currentItemID }) {
                    session.currentItemID = nil
                    session.statusRaw = remaining.allSatisfy { $0.statusRaw == ReviewSessionItemStatus.waiting.rawValue }
                        && status != .paused ? ReviewSessionStatus.waiting.rawValue : ReviewSessionStatus.paused.rawValue
                }
            }
            session.revision = try increment(session.revision)
            session.updatedAt = date
        }
    }
}
