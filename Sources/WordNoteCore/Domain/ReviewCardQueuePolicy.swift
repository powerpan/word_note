import Foundation

public enum ReviewCardAvailability: Equatable, Sendable {
    case suspended
    case buried(until: Date)
    case relearningWaiting(until: Date)
    case relearningLimit(until: Date)
    case newCard
    case priority
    case relearningDue
    case due
    case notDue

    public var isScheduledNow: Bool { self == .priority || self == .relearningDue || self == .due }
}

/// Classifies the next presentation, not an already-presented session item being restored.
public struct ReviewCardQueuePolicy: Sendable {
    public init() {}

    public func availability(of schedule: ReviewCardSchedule, at date: Date, studyTimeZoneID: String,
                             lastInteractionAt: Date? = nil) throws -> ReviewCardAvailability {
        let clock = try schedule.studyClock(at: date, timeZoneID: studyTimeZoneID, lastInteractionAt: lastInteractionAt)
        if schedule.phase == .suspended { return .suspended }
        if let until = schedule.buriedUntil, until > date { return .buried(until: until) }
        if schedule.phase == .new { return .newCard }
        if schedule.phase == .relearning {
            let bucket = try schedule.relearningBucket(at: clock)
            if bucket.repeats >= ReviewCardScheduler.maximumDailyRepeats { return .relearningLimit(until: bucket.day.end) }
            guard let due = schedule.nextReviewAt else { throw WordNoteSnapshotError.invalidValue }
            return due <= date ? .relearningDue : .relearningWaiting(until: due)
        }
        if schedule.priorityRequestedAt != nil { return .priority }
        let tomorrow = try ReviewStudyDay(containing: date, timeZoneID: studyTimeZoneID).end
        return schedule.nextReviewAt.map { $0 < tomorrow } == true ? .due : .notDue
    }
}
