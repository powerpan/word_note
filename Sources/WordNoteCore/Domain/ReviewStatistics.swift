import Foundation

public struct ReviewRecallRate: Equatable, Sendable {
    public let successes: Int
    public let samples: Int
    public var ratio: Double? { samples == 0 ? nil : Double(successes) / Double(samples) }
}

public struct ReviewAnswerStatistics: Equatable, Sendable {
    public let answerCount: Int
    public let answeredCardCount: Int
    public let completedCardCount: Int
    public let failureCount: Int
    public let firstRecall: ReviewRecallRate
    public let hasEstimatedOrder: Bool
    public let clockAnomalyCount: Int
}

public struct ReviewWorkload: Equatable, Sendable {
    public var readyCards = 0
    public var waitingRelearningCards = 0
    public var newCards = 0
    public var buriedCards = 0
    public var suspendedCards = 0
    public var missingAnswerCards = 0
    public var pendingPriorityTerms = 0
    public var nextRelearningAt: Date?
}

public struct ReviewStatisticsSnapshot: Equatable, Sendable {
    public let asOf: Date
    public let studyDayKey: String
    public let studyTimeZoneID: String
    public let courseID: UUID?
    public let mode: ReviewMode?
    public let today: ReviewAnswerStatistics
    public let lifetime: ReviewAnswerStatistics
    public let workload: ReviewWorkload
}

public struct ReviewSessionStatistics: Equatable, Sendable {
    public let asOf: Date
    public let sessionID: UUID
    public let status: ReviewSessionStatus
    public let totalItems: Int
    public let processedItems: Int
    public let reviewed: Int
    public let manualLater: Int
    public let relearningLimit: Int
    public let unclassifiedPostponed: Int
    public let siblingDeferred: Int
    public let unavailable: Int
    public let unverifiedCompleted: Int
    public let waiting: Int
    public let remaining: Int
    public let answers: ReviewAnswerStatistics
    public var processedRatio: Double? { totalItems == 0 ? nil : Double(processedItems) / Double(totalItems) }
}

/// Snapshot-only statistics shared by Dashboard, Course and Review. No counters are written back.
public struct ReviewStatisticsBuilder: Sendable {
    private let payload: WordNoteSnapshotV3Payload
    private let answers: [Answer]
    private let firstAnswerIDs: Set<UUID>

    public init(payload: WordNoteSnapshotV3Payload) throws {
        try payload.validate()
        self.payload = payload
        let events = Dictionary(uniqueKeysWithValues: payload.content.content.reviewEvents.map { ($0.id, $0) })
        let answers = try payload.eventStates.filter { $0.feedbackSemanticsVersion == 2 && $0.invalidatedAt == nil }.map { state in
            guard let event = events[state.id], let cardID = state.originalCardID, let day = state.studyDayKey,
                  let sessionID = state.sessionID, let actionID = state.actionID,
                  let before = state.beforeSchedule, let after = state.afterSchedule else { throw WordNoteSnapshotError.missingReference }
            let feedback: ReviewFeedback = try snapshotEnum(event.feedbackRaw)
            let limited = after.phase != .relearning && (feedback == .again || (feedback == .hard && before.phase == .relearning))
            return Answer(id: state.id, cardID: cardID, termID: event.termID, sessionID: sessionID, actionID: actionID,
                day: day, mode: try snapshotEnum(event.modeRaw), reviewedAt: event.reviewedAt, order: state.recordedOrder,
                failed: feedback == .again, completed: after.phase != .relearning && !limited,
                limited: limited, anomaly: state.clockAnomaly != nil)
        }.sorted(by: Answer.precedes)
        self.answers = answers
        var seen = Set<DailyCard>(), first = Set<UUID>()
        for answer in answers where seen.insert(.init(day: answer.day, cardID: answer.cardID)).inserted { first.insert(answer.id) }
        firstAnswerIDs = first
    }

    public func overview(courseID: UUID? = nil, mode: ReviewMode? = nil, studyTimeZoneID: String,
                         at date: Date = Date()) throws -> ReviewStatisticsSnapshot {
        try classifiedOverview(courseID: courseID, mode: mode, studyTimeZoneID: studyTimeZoneID, at: date).statistics
    }

    func classifiedOverview(courseID: UUID?, mode: ReviewMode?, studyTimeZoneID: String, at date: Date) throws
        -> (statistics: ReviewStatisticsSnapshot, cards: [ReviewCardLearningItem]) {
        let day = try ReviewStudyDay(containing: date, timeZoneID: studyTimeZoneID)
        if let courseID, !payload.content.content.courses.contains(where: { $0.id == courseID }) {
            throw WordNoteV3ContentError.missingEntity
        }
        let courseTerms = Set(payload.content.courseLinks.filter { $0.courseID == courseID }.map(\.termID))
        let selected = answers.filter { (courseID == nil || courseTerms.contains($0.termID)) && (mode == nil || $0.mode == mode) }
        let cards = try ReviewCardLearningIndex(validatedPayload: payload, studyTimeZoneID: studyTimeZoneID, at: date)
            .matching(courseID: courseID, query: .init(mode: mode))
        return (.init(asOf: date, studyDayKey: day.key, studyTimeZoneID: studyTimeZoneID, courseID: courseID, mode: mode,
            today: summary(selected.filter { $0.day == day.key }), lifetime: summary(selected),
            workload: ReviewCardLearningIndex.workload(cards)), cards)
    }

    public func session(_ id: UUID, at date: Date = Date()) throws -> ReviewSessionStatistics {
        try ReviewStateValidation.date(date)
        guard let session = payload.sessions.first(where: { $0.id == id }) else { throw WordNoteV3ContentError.missingEntity }
        let items = payload.sessionItems.filter { $0.sessionID == id }
        let selected = answers.filter { $0.sessionID == id }
        let byAction = Dictionary(uniqueKeysWithValues: selected.map { ($0.actionID, $0) })
        let manuallyPostponed = Set((session.controls?.records ?? []).filter { $0.kind == .later }.map(\.itemID))
        var reviewed = 0, manual = 0, limited = 0, unclassified = 0, unverified = 0
        for item in items {
            let last = item.lastActionID.flatMap { byAction[$0] }.flatMap { $0.cardID == item.originalCardID ? $0 : nil }
            if item.status == .completed {
                if last?.completed == true { reviewed += 1 } else { unverified += 1 }
            }
            if item.status == .postponed {
                if manuallyPostponed.contains(item.id) { manual += 1 }
                else if last?.limited == true { limited += 1 }
                else { unclassified += 1 }
            }
        }
        let processed = items.filter { $0.status.isTerminal }.count
        return .init(asOf: date, sessionID: id, status: session.status, totalItems: items.count, processedItems: processed,
            reviewed: reviewed, manualLater: manual, relearningLimit: limited, unclassifiedPostponed: unclassified,
            siblingDeferred: items.filter { $0.status == .siblingDeferred }.count,
            unavailable: items.filter { $0.status == .unavailable }.count, unverifiedCompleted: unverified,
            waiting: items.filter { $0.status == .waiting }.count, remaining: items.count - processed, answers: summary(selected))
    }

    private func summary(_ values: [Answer]) -> ReviewAnswerStatistics {
        let first = values.filter { firstAnswerIDs.contains($0.id) }
        return .init(answerCount: values.count, answeredCardCount: Set(values.map(\.cardID)).count,
            completedCardCount: Set(values.filter(\.completed).map(\.cardID)).count, failureCount: values.filter(\.failed).count,
            firstRecall: .init(successes: first.filter { !$0.failed }.count, samples: first.count),
            hasEstimatedOrder: values.contains { $0.order == nil }, clockAnomalyCount: values.filter(\.anomaly).count)
    }

    private struct DailyCard: Hashable { let day: String; let cardID: UUID }
    private struct Answer: Sendable {
        let id: UUID
        let cardID: UUID
        let termID: UUID
        let sessionID: UUID
        let actionID: UUID
        let day: String
        let mode: ReviewMode
        let reviewedAt: Date
        let order: Int?
        let failed: Bool
        let completed: Bool
        let limited: Bool
        let anomaly: Bool

        static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
            switch (lhs.order, rhs.order) {
            case (.some(let a), .some(let b)): return a < b
            case (.none, .some): return true
            case (.some, .none): return false
            case (.none, .none): return (lhs.reviewedAt, lhs.id.uuidString) < (rhs.reviewedAt, rhs.id.uuidString)
            }
        }
    }
}
