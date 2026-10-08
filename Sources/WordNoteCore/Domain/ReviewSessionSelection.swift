import Foundation

struct ReviewSessionSelection {
    let scope: ReviewSessionScopeSnapshot
    let cardIDs: [UUID]

    init(payload: WordNoteSnapshotV3Payload, scope requested: ReviewSessionScopeSnapshot,
         target: Int, newCardLimit: Int, at date: Date) throws {
        guard (5...100).contains(target), (0...50).contains(newCardLimit) else { throw WordNoteSnapshotError.invalidValue }
        var scope = requested
        scope.courseName = nil
        if let id = scope.courseID {
            guard let course = payload.content.content.courses.first(where: { $0.id == id }) else { throw WordNoteV3ContentError.missingEntity }
            scope.courseName = course.courseName
        }
        let quota = try ReviewNewCardQuota(payload: payload, limit: newCardLimit, at: date, timeZoneID: scope.studyTimeZoneID)
        let terms = Dictionary(uniqueKeysWithValues: payload.content.content.terms.map { ($0.id, $0) })
        let courseTerms = Set(payload.content.courseLinks.filter { $0.courseID == scope.courseID }.map(\.termID))
        let events = Dictionary(uniqueKeysWithValues: payload.content.content.reviewEvents.map { ($0.id, $0) })
        let failures = Dictionary(grouping: payload.eventStates.filter {
            $0.feedbackSemanticsVersion == 2 && $0.invalidatedAt == nil && events[$0.id]?.feedbackRaw == ReviewFeedback.again.rawValue
        }, by: \.originalCardID).mapValues(\.count)
        var candidates: [Candidate] = []
        for card in payload.cards where card.mode == scope.mode && (scope.courseID == nil || courseTerms.contains(card.termID)) {
            guard let term = terms[card.termID] else { throw WordNoteSnapshotError.missingReference }
            let failureCount = failures[card.id, default: 0]
            if scope.queue == .weakTerms, failureCount == 0, card.schedule.priorityRequestedAt == nil { continue }
            if card.mode == .chineseToEnglish, term.chineseMeaning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { continue }
            let available = try ReviewCardQueuePolicy().availability(of: card.schedule, at: date,
                studyTimeZoneID: scope.studyTimeZoneID, lastInteractionAt: card.updatedAt)
            let rank: Int
            switch available {
            case .relearningDue: rank = 0
            case .priority: rank = 1
            case .due: rank = 2
            case .newCard:
                if card.schedule.introducedAt != nil { rank = 2 }
                else if scope.includesNewCards { rank = 3 }
                else { continue }
            default: continue
            }
            candidates.append(.init(card: card, rank: rank, failures: failureCount, importance: try snapshotEnum(term.importanceRaw)))
        }
        var selected: [UUID] = [], remaining = quota.remaining
        for candidate in candidates.sorted(by: Candidate.precedes) {
            if candidate.rank == 3 {
                guard remaining > 0 else { continue }
                remaining -= 1
            }
            selected.append(candidate.card.id)
            if selected.count == target { break }
        }
        self.scope = scope
        cardIDs = selected
    }

    private struct Candidate {
        let card: WordNoteSnapshotV3Payload.Card
        let rank: Int
        let failures: Int
        let importance: Importance

        static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.card.schedule.nextReviewAt != rhs.card.schedule.nextReviewAt {
                return (lhs.card.schedule.nextReviewAt ?? .distantFuture) < (rhs.card.schedule.nextReviewAt ?? .distantFuture)
            }
            if lhs.card.schedule.priorityRequestedAt != rhs.card.schedule.priorityRequestedAt {
                return (lhs.card.schedule.priorityRequestedAt ?? .distantFuture) < (rhs.card.schedule.priorityRequestedAt ?? .distantFuture)
            }
            if lhs.failures != rhs.failures { return lhs.failures > rhs.failures }
            if lhs.importance != rhs.importance { return lhs.importance > rhs.importance }
            if lhs.card.createdAt != rhs.card.createdAt { return lhs.card.createdAt < rhs.card.createdAt }
            return lhs.card.id.uuidString < rhs.card.id.uuidString
        }
    }
}
