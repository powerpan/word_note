import Foundation

public enum ReviewCardBrowseState: String, CaseIterable, Identifiable, Sendable {
    case ready, new, waiting, deferred, suspended, missingAnswer, scheduled
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ready: "Ready now"
        case .new: "New cards"
        case .waiting: "Relearning later"
        case .deferred: "Deferred related cards"
        case .suspended: "Suspended"
        case .missingAnswer: "Missing answers"
        case .scheduled: "Scheduled later"
        }
    }
}

public struct VocabularyCardQuery: Equatable, Sendable {
    public var mode: ReviewMode?
    public var mastery: MasteryLevel?
    public var state: ReviewCardBrowseState?
    public init(mode: ReviewMode? = nil, mastery: MasteryLevel? = nil, state: ReviewCardBrowseState? = nil) {
        self.mode = mode; self.mastery = mastery; self.state = state
    }
    public var isActive: Bool { mode != nil || mastery != nil || state != nil }
}

public struct ReviewCardLearningItem: Equatable, Sendable, Identifiable {
    public let card: WordNoteSnapshotV3Payload.Card
    public let term: WordNoteSnapshotPayload.Term
    public let courseIDs: Set<UUID>
    public let availability: ReviewCardAvailability?
    public let failureCount: Int
    public var id: UUID { card.id }
    public var isWeak: Bool { failureCount > 0 || card.schedule.priorityRequestedAt != nil }

    public var state: ReviewCardBrowseState {
        switch availability {
        case .suspended: .suspended
        case .buried: .deferred
        case .relearningWaiting, .relearningLimit: .waiting
        case .newCard: card.schedule.introducedAt == nil ? .new : .ready
        case .priority, .due, .relearningDue: .ready
        case .notDue: .scheduled
        case nil: .missingAnswer
        }
    }

    public var waitingUntil: Date? {
        switch availability {
        case .relearningWaiting(let until), .relearningLimit(let until): max(until, card.schedule.nextReviewAt ?? until)
        default: nil
        }
    }

    public func matches(_ query: VocabularyCardQuery) -> Bool {
        (query.mode == nil || card.mode == query.mode)
            && (query.mastery == nil || card.schedule.masteryLevel == query.mastery)
            && (query.state == nil || state == query.state)
    }
}

/// One classification for visible card rows, workload counts and card-based vocabulary filters.
public struct ReviewCardLearningIndex: Sendable {
    public let items: [ReviewCardLearningItem]

    public init(payload: WordNoteSnapshotV3Payload, studyTimeZoneID: String, at date: Date) throws {
        try payload.validate()
        try self.init(validatedPayload: payload, studyTimeZoneID: studyTimeZoneID, at: date)
    }

    init(validatedPayload payload: WordNoteSnapshotV3Payload, studyTimeZoneID: String, at date: Date) throws {
        _ = try ReviewStudyDay(containing: date, timeZoneID: studyTimeZoneID)
        let terms = Dictionary(uniqueKeysWithValues: payload.content.content.terms.map { ($0.id, $0) })
        let occurrences = Dictionary(uniqueKeysWithValues: payload.content.occurrences.map { ($0.id, $0) })
        let memberships = Dictionary(grouping: payload.content.courseLinks, by: \.termID).mapValues { Set($0.map(\.courseID)) }
        let events = Dictionary(uniqueKeysWithValues: payload.content.content.reviewEvents.map { ($0.id, $0) })
        let failures = Dictionary(grouping: payload.eventStates.filter {
            $0.feedbackSemanticsVersion == 2 && $0.invalidatedAt == nil && events[$0.id]?.feedbackRaw == ReviewFeedback.again.rawValue
        }, by: \.originalCardID).mapValues(\.count)
        items = try payload.cards.map { card in
            guard let term = terms[card.termID] else { throw WordNoteSnapshotError.missingReference }
            let availability: ReviewCardAvailability?
            if card.schedule.phase == .suspended { availability = .suspended }
            else if (try? ReviewQuestionContent.front(card: card, term: term,
                occurrence: card.clozeTarget.flatMap { occurrences[$0.occurrenceID] })) == nil { availability = nil }
            else {
                availability = try ReviewCardQueuePolicy().availability(of: card.schedule, at: date,
                    studyTimeZoneID: studyTimeZoneID, lastInteractionAt: card.updatedAt)
            }
            return .init(card: card, term: term, courseIDs: memberships[term.id, default: []],
                         availability: availability, failureCount: failures[card.id, default: 0])
        }
    }

    public func matching(courseID: UUID? = nil, query: VocabularyCardQuery = .init()) -> [ReviewCardLearningItem] {
        items.filter { item in (courseID.map { item.courseIDs.contains($0) } ?? true) && item.matches(query) }
    }

    public static func workload(_ items: [ReviewCardLearningItem]) -> ReviewWorkload {
        var result = ReviewWorkload()
        result.pendingPriorityTerms = Set(items.filter { $0.card.schedule.priorityRequestedAt != nil }.map { $0.term.id }).count
        for item in items {
            switch item.state {
            case .ready: result.readyCards += 1
            case .new: result.newCards += 1
            case .waiting:
                result.waitingRelearningCards += 1
                if let date = item.waitingUntil { result.nextRelearningAt = min(result.nextRelearningAt ?? date, date) }
            case .deferred: result.buriedCards += 1
            case .suspended: result.suspendedCards += 1
            case .missingAnswer: result.missingAnswerCards += 1
            case .scheduled: break
            }
        }
        return result
    }
}
