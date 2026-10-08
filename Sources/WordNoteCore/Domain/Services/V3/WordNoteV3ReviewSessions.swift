import Foundation

extension WordNoteV3ReviewService {
    public func resumableSession() throws -> WordNoteV3ReviewSessionSnapshot? {
        try content.transaction {
            guard let session = try content.fetch(Session.self).first(where: {
                try Payload.Session($0).status.isResumable
            }) else { return nil }
            return try sessionSnapshot(session.id)
        }
    }

    public func reviewSession(_ id: UUID) throws -> WordNoteV3ReviewSessionSnapshot {
        try content.transaction { try sessionSnapshot(id) }
    }

    public func newCardQuota(limit: Int = 10, studyTimeZoneID: String, at date: Date = Date()) throws -> ReviewNewCardQuota {
        try content.transaction {
            try ReviewNewCardQuota(payload: Payload.capture(from: context), limit: limit, at: date, timeZoneID: studyTimeZoneID)
        }
    }

    public func startSession(id: UUID = UUID(), scope: ReviewSessionScopeSnapshot, targetCardCount: Int = 20,
                             newCardLimit: Int = 10, at date: Date = Date()) throws -> WordNoteV3ReviewSessionSnapshot {
        try content.transaction {
            try content.validateDate(date)
            guard (5...100).contains(targetCardCount), (0...50).contains(newCardLimit),
                  TimeZone(identifier: scope.studyTimeZoneID) != nil else { throw WordNoteSnapshotError.invalidValue }
            let snapshot = try Payload.capture(from: context)
            if let existing = snapshot.sessions.first(where: { $0.id == id }) {
                var requestScope = scope
                requestScope.courseName = existing.scope.courseName
                guard existing.scope == requestScope, existing.targetCardCount == targetCardCount,
                      existing.newCardLimitSnapshot == newCardLimit else { throw WordNoteV3ReviewError.actionConflict }
                return try sessionSnapshot(id)
            }
            if let active = snapshot.sessions.first(where: { $0.status.isResumable }) {
                throw WordNoteV3ReviewError.activeSessionExists(active.id)
            }
            let selection = try ReviewSessionSelection(payload: snapshot, scope: scope, target: targetCardCount,
                newCardLimit: newCardLimit, at: date)
            guard !selection.cardIDs.isEmpty else { throw WordNoteV3ReviewError.noEligibleCards }
            let session = Session(id: id, scopeSnapshotJSON: try ReviewPersistenceJSON.encode(selection.scope),
                targetCardCount: targetCardCount, newCardLimitSnapshot: newCardLimit, createdAt: date)
            session.introductionsJSON = try ReviewPersistenceJSON.encode([ReviewNewCardIntroduction]())
            session.controlsJSON = try ReviewPersistenceJSON.encode(ReviewSessionControls())
            session.statusRaw = ReviewSessionStatus.active.rawValue
            for (position, cardID) in selection.cardIDs.enumerated() {
                let item = Item(sessionID: id, cardID: cardID, position: position, createdAt: date)
                if position == 0 { session.currentItemID = item.id }
                context.insert(item)
            }
            context.insert(session)
            return try sessionSnapshot(id)
        }
    }

    public func pauseSession(lease: WordNoteV3ReviewLease, expectedRevision: Int, at date: Date = Date()) throws -> WordNoteV3ReviewSessionSnapshot {
        let result = try changeSession(lease: lease, expectedRevision: expectedRevision, at: date) { session in
            session.statusRaw = ReviewSessionStatus.paused.rawValue
        }
        releaseLease(lease)
        return result
    }

    public func resumeSession(lease: WordNoteV3ReviewLease, expectedRevision: Int, at date: Date = Date()) throws -> WordNoteV3ReviewSessionSnapshot {
        let result = try changeSession(lease: lease, expectedRevision: expectedRevision, at: date) { session in
            guard session.statusRaw == ReviewSessionStatus.paused.rawValue else { return }
            try resetSkipRound(in: session)
            let items = try sessionSnapshot(session.id).items.filter { !$0.status.isTerminal }
            if items.isEmpty {
                session.currentItemID = nil
                session.statusRaw = ReviewSessionStatus.completed.rawValue
                session.endedAt = max(session.updatedAt, date)
                return
            }
            let current = items.first { $0.id == session.currentItemID && $0.status != .waiting }
                ?? items.first { $0.status != .waiting }
            session.currentItemID = current?.id
            session.statusRaw = current == nil ? ReviewSessionStatus.waiting.rawValue : ReviewSessionStatus.active.rawValue
        }
        if !result.session.status.isResumable { releaseLease(lease) }
        return result
    }

    public func endSession(lease: WordNoteV3ReviewLease, expectedRevision: Int, at date: Date = Date()) throws -> WordNoteV3ReviewSessionSnapshot {
        let result = try changeSession(lease: lease, expectedRevision: expectedRevision, at: date) { session in
            session.statusRaw = ReviewSessionStatus.ended.rawValue
            session.currentItemID = nil
            session.endedAt = max(session.updatedAt, date)
        }
        releaseLease(lease)
        return result
    }

    func sessionSnapshot(_ id: UUID) throws -> WordNoteV3ReviewSessionSnapshot {
        let items = try content.fetch(Item.self).filter { $0.sessionID == id }.map { try Payload.SessionItem($0) }
            .sorted { ($0.position, $0.id.uuidString) < ($1.position, $1.id.uuidString) }
        return try .init(session: Payload.Session(session(id)), items: items)
    }

    private func changeSession(lease: WordNoteV3ReviewLease, expectedRevision: Int, at date: Date,
                               change: (Session) throws -> Void) throws -> WordNoteV3ReviewSessionSnapshot {
        try content.transaction {
            _ = try WordNoteV3ReviewOwnership.require(lease, in: context)
            try content.validateDate(date)
            let session = try session(lease.sessionID)
            try content.requireRevision(session.revision, expectedRevision)
            guard try Payload.Session(session).status.isResumable else { throw WordNoteV3ReviewError.noActivePresentedItem }
            let before = try Payload.Session(session)
            try change(session)
            if try Payload.Session(session) != before {
                session.revision = try content.increment(session.revision)
                session.updatedAt = max(session.updatedAt, date)
            }
            return try sessionSnapshot(session.id)
        }
    }
}
