import Foundation

extension ReviewCardSchedule {
    init(_ model: WordNoteSchemaV3.ReviewCardModel) throws {
        phase = try snapshotEnum(model.phaseRaw)
        masteryLevel = try snapshotEnum(model.masteryLevelRaw)
        intervalDays = model.intervalDays
        confidentStreak = model.confidentStreak
        lapseCount = model.lapseCount
        nextReviewAt = model.nextReviewAt
        priorityRequestedAt = model.priorityRequestedAt
        introducedAt = model.introducedAt
        lastReviewedAt = model.lastReviewedAt
        relearningDayKey = model.relearningDayKey
        relearningTimeZoneID = model.relearningTimeZoneID
        relearningRepeatCount = model.relearningRepeatCount
        buriedUntil = model.buriedUntil
    }

    func apply(to model: WordNoteSchemaV3.ReviewCardModel) {
        model.phaseRaw = phase.rawValue
        model.masteryLevelRaw = masteryLevel.rawValue
        model.intervalDays = intervalDays
        model.confidentStreak = confidentStreak
        model.lapseCount = lapseCount
        model.nextReviewAt = nextReviewAt
        model.priorityRequestedAt = priorityRequestedAt
        model.introducedAt = introducedAt
        model.lastReviewedAt = lastReviewedAt
        model.relearningDayKey = relearningDayKey
        model.relearningTimeZoneID = relearningTimeZoneID
        model.relearningRepeatCount = relearningRepeatCount
        model.buriedUntil = buriedUntil
    }
}

extension WordNoteSnapshotV3Payload.TermHistory {
    init(_ model: WordNoteSchemaV3.TermModel) {
        id = model.id
        legacyWrongCount = model.legacyWrongCount
        legacyReviewCount = model.legacyReviewCount
        legacyDuplicateHitCount = model.legacyDuplicateHitCount
        legacySnapshotAt = model.legacySnapshotAt
    }

    func apply(to model: WordNoteSchemaV3.TermModel) {
        model.legacyWrongCount = legacyWrongCount
        model.legacyReviewCount = legacyReviewCount
        model.legacyDuplicateHitCount = legacyDuplicateHitCount
        model.legacySnapshotAt = legacySnapshotAt
    }
}

extension WordNoteSnapshotV3Payload.Card {
    public init(_ model: WordNoteSchemaV3.ReviewCardModel) throws {
        id = model.id
        termID = model.termID
        contentScopeKey = model.contentScopeKey
        revision = model.revision
        schedulerVersion = model.schedulerVersion
        createdAt = model.createdAt
        updatedAt = model.updatedAt
        mode = try snapshotEnum(model.modeRaw)
        schedule = try ReviewCardSchedule(model)
        clozeTarget = try model.clozeTargetJSON.map { try ReviewPersistenceJSON.decode($0) }
    }

    func model() throws -> WordNoteSchemaV3.ReviewCardModel {
        let model = WordNoteSchemaV3.ReviewCardModel(id: id, termID: termID, mode: mode, createdAt: createdAt)
        model.contentScopeKey = contentScopeKey
        model.revision = revision
        model.schedulerVersion = schedulerVersion
        model.updatedAt = updatedAt
        schedule.apply(to: model)
        model.clozeTargetJSON = try clozeTarget.map { try ReviewPersistenceJSON.encode($0) }
        return model
    }
}

extension WordNoteSnapshotV3Payload.Session {
    public init(_ model: WordNoteSchemaV3.ReviewSessionModel) throws {
        id = model.id
        targetCardCount = model.targetCardCount
        newCardLimitSnapshot = model.newCardLimitSnapshot
        currentItemID = model.currentItemID
        createdAt = model.createdAt
        updatedAt = model.updatedAt
        endedAt = model.endedAt
        revision = model.revision
        status = try snapshotEnum(model.statusRaw)
        scope = try ReviewPersistenceJSON.decode(model.scopeSnapshotJSON)
    }

    func model() throws -> WordNoteSchemaV3.ReviewSessionModel {
        let model = WordNoteSchemaV3.ReviewSessionModel(id: id, scopeSnapshotJSON: try ReviewPersistenceJSON.encode(scope),
            targetCardCount: targetCardCount, newCardLimitSnapshot: newCardLimitSnapshot, createdAt: createdAt)
        model.currentItemID = currentItemID
        model.updatedAt = updatedAt
        model.endedAt = endedAt
        model.revision = revision
        model.statusRaw = status.rawValue
        return model
    }
}

extension WordNoteSnapshotV3Payload.SessionItem {
    public init(_ model: WordNoteSchemaV3.ReviewSessionItemModel) throws {
        id = model.id
        sessionID = model.sessionID
        cardID = model.cardID
        originalCardID = model.originalCardID
        position = model.position
        attemptCount = model.attemptCount
        availableAt = model.availableAt
        lastActionID = model.lastActionID
        createdAt = model.createdAt
        updatedAt = model.updatedAt
        status = try snapshotEnum(model.statusRaw)
        completionOutcome = try model.completionOutcomeRaw.map { try snapshotEnum($0) }
    }

    func model() -> WordNoteSchemaV3.ReviewSessionItemModel {
        let model = WordNoteSchemaV3.ReviewSessionItemModel(id: id, sessionID: sessionID, cardID: originalCardID, position: position, createdAt: createdAt)
        model.cardID = cardID
        model.attemptCount = attemptCount
        model.availableAt = availableAt
        model.lastActionID = lastActionID
        model.updatedAt = updatedAt
        model.statusRaw = status.rawValue
        model.completionOutcomeRaw = completionOutcome?.rawValue
        return model
    }
}

extension WordNoteSnapshotV3Payload.EventState {
    init(_ model: WordNoteSchemaV3.ReviewEventModel) throws {
        id = model.id
        cardID = model.cardID
        originalCardID = model.originalCardID
        sessionID = model.sessionID
        actionID = model.actionID
        feedbackSemanticsVersion = model.feedbackSemanticsVersion
        schedulerVersion = model.schedulerVersion
        studyDayKey = model.studyDayKey
        studyTimeZoneID = model.studyTimeZoneID
        invalidatedAt = model.invalidatedAt
        beforeSchedule = try model.beforeScheduleJSON.map { try ReviewPersistenceJSON.decode($0) }
        afterSchedule = try model.afterScheduleJSON.map { try ReviewPersistenceJSON.decode($0) }
        clockAnomaly = try model.clockAnomalyRaw.map { try snapshotEnum($0) }
    }

    func apply(to model: WordNoteSchemaV3.ReviewEventModel) throws {
        model.cardID = cardID
        model.originalCardID = originalCardID
        model.sessionID = sessionID
        model.actionID = actionID
        model.feedbackSemanticsVersion = feedbackSemanticsVersion
        model.schedulerVersion = schedulerVersion
        model.studyDayKey = studyDayKey
        model.studyTimeZoneID = studyTimeZoneID
        model.invalidatedAt = invalidatedAt
        model.beforeScheduleJSON = try beforeSchedule.map { try ReviewPersistenceJSON.encode($0) }
        model.afterScheduleJSON = try afterSchedule.map { try ReviewPersistenceJSON.encode($0) }
        model.clockAnomalyRaw = clockAnomaly?.rawValue
    }
}
