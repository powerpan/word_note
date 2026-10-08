import Foundation

enum ReviewStateValidation {
    static let maximumCounter = 1_000_000_000

    static func counter(_ value: Int) throws {
        guard (0...maximumCounter).contains(value) else { throw WordNoteSnapshotError.invalidValue }
    }

    static func date(_ value: Date?) throws {
        guard let value else { return }
        guard value.timeIntervalSince1970.isFinite, abs(value.timeIntervalSince1970) < 100_000_000_000 else {
            throw WordNoteSnapshotError.invalidValue
        }
    }
}

extension ReviewCardSchedule {
    /// The scheduler and complete V3 snapshot use the same scalar/state constraints.
    func validate() throws {
        try [intervalDays, confidentStreak, lapseCount].forEach(ReviewStateValidation.counter)
        guard (0...2).contains(relearningRepeatCount) else { throw WordNoteSnapshotError.invalidValue }
        _ = try ReviewStudyDay.optional(key: relearningDayKey, timeZoneID: relearningTimeZoneID, required: relearningRepeatCount > 0)
        try [nextReviewAt, priorityRequestedAt, introducedAt, lastReviewedAt, buriedUntil].forEach(ReviewStateValidation.date)
        switch phase {
        case .new:
            guard nextReviewAt == nil, masteryLevel == .new, intervalDays == 0,
                  confidentStreak == 0, lapseCount == 0, lastReviewedAt == nil,
                  relearningRepeatCount == 0 else { throw WordNoteSnapshotError.invalidValue }
        case .review:
            guard nextReviewAt != nil else { throw WordNoteSnapshotError.invalidValue }
        case .relearning:
            guard nextReviewAt != nil, masteryLevel == .vague, confidentStreak == 0 else { throw WordNoteSnapshotError.invalidValue }
            _ = try ReviewStudyDay.optional(key: relearningDayKey, timeZoneID: relearningTimeZoneID, required: true)
        case .suspended: break
        }
    }
}
