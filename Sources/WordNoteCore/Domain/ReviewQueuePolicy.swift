import Foundation

public enum ReviewQueueScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case dueToday
    case weakTerms

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .dueToday:
            return "Due Today"
        case .weakTerms:
            return "Weak Terms"
        }
    }
}

public struct ReviewQueuePolicy {
    public init() {}

    public func terms(
        from terms: [TermModel],
        scope: ReviewQueueScope = .dueToday,
        asOf date: Date = Date(),
        courseID: UUID? = nil,
        calendar: Calendar = .current
    ) -> [TermModel] {
        let startOfToday = calendar.startOfDay(for: date)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)
            ?? date.addingTimeInterval(24 * 60 * 60)

        return terms
            .filter { term in
                let courseMatches = courseID == nil || term.courseID == courseID
                guard courseMatches else { return false }

                switch scope {
                case .dueToday:
                    guard let nextReviewAt = term.nextReviewAt else { return false }
                    return nextReviewAt < startOfTomorrow
                case .weakTerms:
                    return term.wrongCount > 0
                        || term.duplicateHitCount > 0
                        || term.masteryLevel == .vague
                }
            }
            .sorted { lhs, rhs in
                switch scope {
                case .dueToday:
                    if lhs.nextReviewAt != rhs.nextReviewAt {
                        return (lhs.nextReviewAt ?? .distantFuture) < (rhs.nextReviewAt ?? .distantFuture)
                    }
                case .weakTerms:
                    if lhs.wrongCount != rhs.wrongCount {
                        return lhs.wrongCount > rhs.wrongCount
                    }
                    if lhs.duplicateHitCount != rhs.duplicateHitCount {
                        return lhs.duplicateHitCount > rhs.duplicateHitCount
                    }
                }

                if lhs.wrongCount != rhs.wrongCount {
                    return lhs.wrongCount > rhs.wrongCount
                }
                if lhs.duplicateHitCount != rhs.duplicateHitCount {
                    return lhs.duplicateHitCount > rhs.duplicateHitCount
                }
                if lhs.importance != rhs.importance {
                    return lhs.importance > rhs.importance
                }
                return lhs.createdAt < rhs.createdAt
            }
    }
}
