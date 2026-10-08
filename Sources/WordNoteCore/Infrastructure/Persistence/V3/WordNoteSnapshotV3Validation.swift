import CryptoKit
import Foundation

extension WordNoteSnapshotV3Payload {
    public func validate() throws {
        try content.validate()
        guard counts.total <= WordNoteSnapshotPayload.maximumEntityCount else { throw WordNoteSnapshotError.sizeLimit }
        let terms = try indexed(content.content.terms, by: \.id)
        let historyByID = try indexed(termHistories, by: \.id)
        let events = try indexed(content.content.reviewEvents, by: \.id)
        let stateByID = try indexed(eventStates, by: \.id)
        let cardByID = try indexed(cards, by: \.id)
        let sessionByID = try indexed(sessions, by: \.id)
        let itemByID = try indexed(sessionItems, by: \.id)
        let sources = try indexed(content.occurrences, by: \.id)
        guard Set(historyByID.keys) == Set(terms.keys), Set(stateByID.keys) == Set(events.keys) else {
            throw WordNoteSnapshotError.missingReference
        }
        _ = try indexed(cards) { CardKey(termID: $0.termID, mode: $0.mode, scope: $0.contentScopeKey) }
        _ = try indexed(sessionItems) { Pair(first: $0.sessionID, second: $0.originalCardID) }
        _ = try indexed(sessionItems) { Position(sessionID: $0.sessionID, value: $0.position) }
        _ = try indexed(eventStates.compactMap(\.actionID), by: { $0 })
        guard sessions.filter({ $0.status.isResumable }).count <= 1 else { throw WordNoteSnapshotError.invalidValue }
        for history in termHistories {
            let values = [history.legacyWrongCount, history.legacyReviewCount, history.legacyDuplicateHitCount]
            if history.legacySnapshotAt != nil {
                guard values.allSatisfy({ $0 != nil }), let term = terms[history.id],
                      history.legacyWrongCount == term.wrongCount, history.legacyReviewCount == term.reviewCount,
                      history.legacyDuplicateHitCount == term.duplicateHitCount else { throw WordNoteSnapshotError.invalidValue }
            } else {
                guard !values.contains(where: { $0 != nil }), let term = terms[history.id],
                      term.reviewCount == 0, term.wrongCount == 0, term.duplicateHitCount == 0 else { throw WordNoteSnapshotError.invalidValue }
            }
            try values.compactMap { $0 }.forEach(counter)
            try date(history.legacySnapshotAt)
        }
        for card in cards {
            guard terms[card.termID] != nil else { throw WordNoteSnapshotError.missingReference }
            try counter(card.revision)
            try schedule(card.schedule)
            try scheduler(card.schedulerVersion)
            try date(card.createdAt)
            try date(card.updatedAt)
            if card.schedulerVersion == ReviewSchedulerVersion.legacy {
                guard card.schedule.lapseCount == 0, card.schedule.phase != .new,
                      card.schedule.phase != .relearning else { throw WordNoteSnapshotError.invalidValue }
            }
            if card.mode == .contextCloze {
                guard let target = card.clozeTarget, card.contentScopeKey == target.contentScopeKey else { throw WordNoteSnapshotError.invalidValue }
                guard let source = sources[target.occurrenceID], source.termID == card.termID else { throw WordNoteSnapshotError.missingReference }
                try cloze(target, source: source.rawTextSnapshot)
            } else if card.contentScopeKey != "wholeTerm" || card.clozeTarget != nil {
                throw WordNoteSnapshotError.invalidValue
            }
        }
        let itemsBySession = Dictionary(grouping: sessionItems, by: \.sessionID)
        for session in sessions {
            try counter(session.revision)
            try date(session.createdAt)
            try date(session.updatedAt)
            try date(session.endedAt)
            try texts([session.scope.courseName])
            guard (5...100).contains(session.targetCardCount), (0...50).contains(session.newCardLimitSnapshot),
                  TimeZone(identifier: session.scope.studyTimeZoneID) != nil,
                  session.scope.courseID != nil || session.scope.courseName == nil else { throw WordNoteSnapshotError.invalidValue }
            let items = itemsBySession[session.id, default: []]
            guard items.count <= session.targetCardCount else { throw WordNoteSnapshotError.invalidValue }
            if let id = session.currentItemID {
                guard let item = itemByID[id], item.sessionID == session.id, !item.status.isTerminal,
                      item.status != .waiting else { throw WordNoteSnapshotError.missingReference }
            }
            if session.status.isResumable {
                guard session.endedAt == nil else { throw WordNoteSnapshotError.invalidValue }
            } else {
                guard session.endedAt != nil, session.currentItemID == nil else { throw WordNoteSnapshotError.invalidValue }
            }
            if session.status == .active, session.currentItemID == nil { throw WordNoteSnapshotError.invalidValue }
            if session.status == .waiting {
                guard session.currentItemID == nil, items.contains(where: { $0.status == .waiting }),
                      items.allSatisfy({ $0.status.isTerminal || $0.status == .waiting }) else { throw WordNoteSnapshotError.invalidValue }
            }
            if session.status == .completed, !items.allSatisfy({ $0.status.isTerminal }) { throw WordNoteSnapshotError.invalidValue }
        }
        for item in sessionItems {
            guard let session = sessionByID[item.sessionID] else { throw WordNoteSnapshotError.missingReference }
            if let id = item.cardID {
                guard let card = cardByID[id], id == item.originalCardID, card.mode == session.scope.mode else { throw WordNoteSnapshotError.missingReference }
            } else if item.status != .unavailable { throw WordNoteSnapshotError.missingReference }
            try counter(item.position)
            try counter(item.attemptCount)
            try date(item.availableAt)
            try date(item.createdAt)
            try date(item.updatedAt)
            guard (item.status == .waiting) == (item.availableAt != nil) else { throw WordNoteSnapshotError.invalidValue }
            let outcome: ReviewCompletionOutcome?
            switch item.status {
            case .completed: outcome = .reviewed
            case .postponed: outcome = .postponed
            case .siblingDeferred: outcome = .siblingDeferred
            case .unavailable: outcome = .unavailable
            case .pending, .presented, .waiting: outcome = nil
            }
            guard item.completionOutcome == outcome else { throw WordNoteSnapshotError.invalidValue }
        }
        for state in eventStates {
            guard let event = events[state.id] else { throw WordNoteSnapshotError.missingReference }
            try date(state.invalidatedAt)
            try scheduler(state.schedulerVersion)
            if let cardID = state.cardID {
                guard let card = cardByID[cardID], card.termID == event.termID, card.mode.rawValue == event.modeRaw else {
                    throw WordNoteSnapshotError.missingReference
                }
            }
            switch state.feedbackSemanticsVersion {
            case 1:
                guard state.schedulerVersion == ReviewSchedulerVersion.legacy, state.actionID == nil,
                      state.sessionID == nil, state.originalCardID == nil, state.beforeSchedule == nil,
                      state.afterSchedule == nil, state.studyDayKey == nil, state.studyTimeZoneID == nil,
                      state.clockAnomaly == nil else { throw WordNoteSnapshotError.invalidValue }
            case 2:
                guard state.schedulerVersion == ReviewSchedulerVersion.current, state.actionID != nil,
                      let originalCardID = state.originalCardID, let sessionID = state.sessionID,
                      let session = sessionByID[sessionID], session.scope.mode.rawValue == event.modeRaw,
                      let item = itemsBySession[sessionID]?.first(where: { $0.originalCardID == originalCardID }),
                      state.cardID == originalCardID || (state.cardID == nil && item.cardID == nil),
                      let before = state.beforeSchedule, let after = state.afterSchedule else { throw WordNoteSnapshotError.missingReference }
                try studyDay(state.studyDayKey, timeZone: state.studyTimeZoneID, required: true)
                try schedule(before)
                try schedule(after)
                guard before.masteryLevel.rawValue == event.previousMasteryLevelRaw,
                      after.masteryLevel.rawValue == event.newMasteryLevelRaw,
                      before.nextReviewAt == event.previousNextReviewAt, after.nextReviewAt == event.newNextReviewAt,
                      after.lastReviewedAt == event.reviewedAt,
                      after.lapseCount == before.lapseCount + (event.feedbackRaw == ReviewFeedback.again.rawValue ? 1 : 0) else {
                    throw WordNoteSnapshotError.invalidValue
                }
            default: throw WordNoteSnapshotError.invalidValue
            }
        }
        let newEventsByItem = Dictionary(grouping: eventStates.filter { $0.feedbackSemanticsVersion == 2 }) {
            Pair(first: $0.sessionID!, second: $0.originalCardID!)
        }
        for item in sessionItems {
            let answers = newEventsByItem[Pair(first: item.sessionID, second: item.originalCardID), default: []]
            guard item.attemptCount == answers.count || (item.status == .unavailable && item.attemptCount >= answers.count) else {
                throw WordNoteSnapshotError.invalidValue
            }
            if item.status == .completed || item.status == .waiting {
                guard let actionID = item.lastActionID, let last = answers.first(where: { $0.actionID == actionID }),
                      (item.status == .waiting) == (last.afterSchedule?.phase == .relearning) else { throw WordNoteSnapshotError.invalidValue }
            }
        }
    }

    private struct CardKey: Hashable { let termID: UUID; let mode: ReviewMode; let scope: String }
    private struct Pair: Hashable { let first: UUID; let second: UUID }
    private struct Position: Hashable { let sessionID: UUID; let value: Int }

    private func indexed<T, Key: Hashable>(_ values: [T], by key: (T) -> Key) throws -> [Key: T] {
        var result: [Key: T] = [:]
        for value in values {
            guard result.updateValue(value, forKey: key(value)) == nil else { throw WordNoteSnapshotError.duplicateID }
        }
        return result
    }

    private func counter(_ value: Int) throws {
        guard (0...1_000_000_000).contains(value) else { throw WordNoteSnapshotError.invalidValue }
    }

    private func date(_ value: Date?) throws {
        guard let value else { return }
        guard value.timeIntervalSince1970.isFinite, abs(value.timeIntervalSince1970) < 100_000_000_000 else { throw WordNoteSnapshotError.invalidValue }
    }

    private func texts(_ values: [String?]) throws {
        guard values.allSatisfy({ ($0?.count ?? 0) <= WordNoteSnapshotPayload.maximumTextCharacters }) else { throw WordNoteSnapshotError.sizeLimit }
    }

    private func scheduler(_ value: String) throws {
        guard [ReviewSchedulerVersion.legacy, ReviewSchedulerVersion.current].contains(value) else { throw WordNoteSnapshotError.invalidValue }
    }

    private func studyDay(_ key: String?, timeZone: String?, required: Bool) throws {
        if key == nil, timeZone == nil, !required { return }
        guard let key, let timeZone, TimeZone(identifier: timeZone) != nil,
              key.utf8.count == 10, key.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) else { throw WordNoteSnapshotError.invalidValue }
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]), (1...9999).contains(year) else { throw WordNoteSnapshotError.invalidValue }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year, calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { throw WordNoteSnapshotError.invalidValue }
    }

    private func schedule(_ value: ReviewCardSchedule) throws {
        try [value.intervalDays, value.confidentStreak, value.lapseCount].forEach(counter)
        guard (0...2).contains(value.relearningRepeatCount) else { throw WordNoteSnapshotError.invalidValue }
        try studyDay(value.relearningDayKey, timeZone: value.relearningTimeZoneID, required: value.relearningRepeatCount > 0)
        try [value.nextReviewAt, value.priorityRequestedAt, value.introducedAt, value.lastReviewedAt, value.buriedUntil].forEach(date)
        switch value.phase {
        case .new:
            guard value.nextReviewAt == nil, value.masteryLevel == .new, value.intervalDays == 0,
                  value.confidentStreak == 0, value.lapseCount == 0, value.lastReviewedAt == nil,
                  value.relearningRepeatCount == 0 else { throw WordNoteSnapshotError.invalidValue }
        case .review:
            guard value.nextReviewAt != nil else { throw WordNoteSnapshotError.invalidValue }
        case .relearning:
            guard value.nextReviewAt != nil, value.masteryLevel == .vague, value.confidentStreak == 0 else { throw WordNoteSnapshotError.invalidValue }
            try studyDay(value.relearningDayKey, timeZone: value.relearningTimeZoneID, required: true)
        case .suspended: break
        }
    }

    private func cloze(_ target: ReviewClozeTarget, source: String) throws {
        try texts([target.answer] + target.acceptedAnswers.map(Optional.some))
        guard target.acceptedAnswers.count <= 100, !target.answer.isEmpty,
              target.acceptedAnswers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              target.startCharacterOffset >= 0, target.characterCount > 0,
              target.startCharacterOffset <= source.count, target.characterCount <= source.count - target.startCharacterOffset,
              target.sourceHash == Self.sourceHash(source) else { throw WordNoteSnapshotError.invalidValue }
        let start = source.index(source.startIndex, offsetBy: target.startCharacterOffset)
        let end = source.index(start, offsetBy: target.characterCount)
        guard String(source[start..<end]) == target.answer else { throw WordNoteSnapshotError.invalidValue }
    }

    public static func sourceHash(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
