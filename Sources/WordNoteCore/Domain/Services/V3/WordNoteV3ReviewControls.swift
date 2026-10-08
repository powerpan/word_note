import Foundation

extension WordNoteV3ReviewService {
    public func controlReceipt(actionID: UUID) throws -> WordNoteV3ControlReceipt? {
        try content.transaction { try savedControl(actionID: actionID) }
    }

    public func skip(_ source: WordNoteV3ReviewAnswerSnapshot, actionID: UUID,
                     lease: WordNoteV3ReviewLease, at date: Date = Date()) throws -> WordNoteV3ControlReceipt {
        try control(.skip, source: source, actionID: actionID, lease: lease, at: date)
    }

    public func later(_ source: WordNoteV3ReviewAnswerSnapshot, actionID: UUID,
                      lease: WordNoteV3ReviewLease, at date: Date = Date()) throws -> WordNoteV3ControlReceipt {
        try control(.later, source: source, actionID: actionID, lease: lease, at: date)
    }

    func savedControl(actionID: UUID) throws -> WordNoteV3ControlReceipt? {
        for model in try content.fetch(Session.self) {
            let value = try Payload.Session(model)
            if let record = value.controls?.records.first(where: { $0.actionID == actionID }) {
                return .init(sessionID: value.id, record: record, isReplay: true)
            }
        }
        return nil
    }

    func resetSkipRound(in session: Session) throws {
        var controls = try Payload.Session(session).controls ?? ReviewSessionControls()
        controls.skippedItemIDs = []
        session.controlsJSON = try ReviewPersistenceJSON.encode(controls)
    }

    private func control(_ kind: ReviewSessionControlKind, source: WordNoteV3ReviewAnswerSnapshot,
                         actionID: UUID, lease: WordNoteV3ReviewLease, at date: Date) throws -> WordNoteV3ControlReceipt {
        let result = try content.transaction {
            let fingerprint = Payload.sourceHash(try ReviewPersistenceJSON.encode(source))
            if let saved = try savedControl(actionID: actionID) {
                guard saved.sessionID == source.session.id, saved.record.kind == kind,
                      saved.record.itemID == source.item.id, saved.record.originalCardID == source.card.id,
                      saved.record.sourceFingerprint == fingerprint else { throw WordNoteV3ReviewError.actionConflict }
                return saved
            }
            guard try !content.fetch(Event.self).contains(where: { $0.actionID == actionID }) else {
                throw WordNoteV3ReviewError.actionConflict
            }
            _ = try WordNoteV3ReviewOwnership.require(lease, in: context)
            guard lease.sessionID == source.session.id else { throw WordNoteV3ReviewError.invalidLease }
            guard try currentSnapshot(sessionID: lease.sessionID) == source else { throw WordNoteV3ReviewError.stalePreview }
            try content.validateDate(date)
            let session = try session(lease.sessionID)
            var controls = source.session.controls ?? ReviewSessionControls()
            guard controls.records.count < ReviewSessionControls.maximumRecords else { throw WordNoteV3ReviewError.controlRecordLimit }
            let effectiveAt = max(date, source.session.updatedAt, source.item.updatedAt, source.card.updatedAt)
            var postponedUntil: Date?
            switch kind {
            case .skip:
                if !controls.skippedItemIDs.contains(source.item.id) { controls.skippedItemIDs.append(source.item.id) }
                try rotateSkippedItem(source.item.id, in: session, skipped: Set(controls.skippedItemIDs),
                                      at: date, effectiveAt: effectiveAt)
            case .later:
                let plan = try scheduler.postpone(source.card.schedule, at: date,
                    studyTimeZoneID: source.session.scope.studyTimeZoneID, lastInteractionAt: effectiveAt)
                let card = try card(source.card.id)
                plan.after.apply(to: card)
                card.revision = try content.increment(card.revision)
                card.updatedAt = plan.clock.effectiveAt
                card.schedulerVersion = ReviewSchedulerVersion.current
                guard let item = try content.fetch(Item.self).first(where: { $0.id == source.item.id }) else {
                    throw WordNoteV3ContentError.missingEntity
                }
                item.statusRaw = ReviewSessionItemStatus.postponed.rawValue
                item.completionOutcomeRaw = ReviewCompletionOutcome.postponed.rawValue
                item.availableAt = nil
                item.updatedAt = plan.clock.effectiveAt
                postponedUntil = plan.after.nextReviewAt
                controls.skippedItemIDs = []
                try advanceCursor(in: session, at: plan.clock.effectiveAt)
            }
            let record = ReviewSessionControlRecord(actionID: actionID, kind: kind, itemID: source.item.id,
                originalCardID: source.card.id, sourceFingerprint: fingerprint, performedAt: date,
                effectiveAt: max(effectiveAt, session.updatedAt), postponedUntil: postponedUntil,
                resultingRevision: session.revision, resultingStatus: try Payload.Session(session).status)
            controls.records.append(record)
            session.controlsJSON = try ReviewPersistenceJSON.encode(controls)
            return WordNoteV3ControlReceipt(sessionID: session.id, record: record, isReplay: false)
        }
        if !result.isReplay {
            WordNoteV3ReviewOwnership.didSaveAnswer(lease,
                ended: result.record.resultingStatus == .paused || !result.record.resultingStatus.isResumable, in: context)
        }
        return result
    }

    private func rotateSkippedItem(_ id: UUID, in session: Session, skipped: Set<UUID>,
                                   at date: Date, effectiveAt: Date) throws {
        let snapshot = try sessionSnapshot(session.id)
        let ready = try readyRelearningItems(in: snapshot, at: date)
        let available = snapshot.items.filter { $0.status == .pending || $0.status == .presented } + ready
        let rotated = snapshot.items.filter { $0.id != id } + snapshot.items.filter { $0.id == id }
        let models = Dictionary(uniqueKeysWithValues: try content.fetch(Item.self).filter { $0.sessionID == session.id }.map { ($0.id, $0) })
        for (position, item) in rotated.enumerated() {
            if let model = models[item.id], model.position != position {
                model.position = position
                model.updatedAt = max(model.updatedAt, effectiveAt)
            }
        }
        // The cursor remains a non-waiting item. Presentation can prioritize a newly ready repeat.
        session.currentItemID = rotated.first { ($0.status == .pending || $0.status == .presented) && !skipped.contains($0.id) }?.id
            ?? rotated.first { $0.status == .pending || $0.status == .presented }?.id
        session.statusRaw = available.allSatisfy { skipped.contains($0.id) }
            ? ReviewSessionStatus.paused.rawValue : ReviewSessionStatus.active.rawValue
        session.revision = try content.increment(session.revision)
        session.updatedAt = max(session.updatedAt, effectiveAt)
    }
}
