import Foundation

public enum ReviewCardSchedulingError: LocalizedError, Equatable {
    case suspended, buried, relearningNotDue, relearningLimitReached, counterLimit

    public var errorDescription: String? {
        switch self {
        case .suspended: "This review card is suspended."
        case .buried: "This card is deferred to avoid showing related answers on the same day."
        case .relearningNotDue: "This card is still waiting for its relearning time."
        case .relearningLimitReached: "This card has reached today's relearning limit."
        case .counterLimit: "A review counter has reached its supported limit."
        }
    }
}

public enum ReviewScheduleDelay: Equatable, Sendable {
    case minutes(Int)
    case calendarDays(Int)
}

public enum ReviewFeedbackDisposition: Equatable, Sendable {
    case relearning, reviewed, relearningLimitReached
}

public struct ReviewCardFeedbackPlan: Equatable, Sendable {
    public let feedback: ReviewFeedback
    public let before: ReviewCardSchedule
    public let after: ReviewCardSchedule
    public let clock: ReviewStudyClock
    public let delay: ReviewScheduleDelay
    public let disposition: ReviewFeedbackDisposition
    public var countsAsFailure: Bool { feedback == .again }
}

public struct ReviewCardPresentationPlan: Equatable, Sendable {
    public let before: ReviewCardSchedule
    public let after: ReviewCardSchedule
    public let clock: ReviewStudyClock
    public let isRelearningRepeat: Bool
}

public struct ReviewCardPostponementPlan: Equatable, Sendable {
    public let before: ReviewCardSchedule
    public let after: ReviewCardSchedule
    public let clock: ReviewStudyClock
}

/// Pure V3 rules. Persist a presentation only when a session item actually becomes presented.
public struct ReviewCardScheduler: Sendable {
    public static let relearningDelay: TimeInterval = 600
    public static let maximumDailyRepeats = 2

    public init() {}

    public func postpone(_ before: ReviewCardSchedule, at date: Date, studyTimeZoneID: String,
                         lastInteractionAt: Date? = nil) throws -> ReviewCardPostponementPlan {
        let clock = try before.studyClock(at: date, timeZoneID: studyTimeZoneID, lastInteractionAt: lastInteractionAt)
        try requireEnabled(before, at: date)
        var after = before
        let bucket = try before.relearningBucket(at: clock)
        after.nextReviewAt = max(try clock.nextDayStart, before.phase == .relearning ? bucket.day.end : clock.effectiveAt)
        if after.phase == .new { after.phase = .review }
        if let priority = after.priorityRequestedAt, priority <= clock.observedAt { after.priorityRequestedAt = nil }
        try after.validate()
        return .init(before: before, after: after, clock: clock)
    }

    public func presentation(for before: ReviewCardSchedule, at date: Date, studyTimeZoneID: String,
                             lastInteractionAt: Date? = nil) throws -> ReviewCardPresentationPlan {
        let clock = try before.studyClock(at: date, timeZoneID: studyTimeZoneID, lastInteractionAt: lastInteractionAt)
        try requireEnabled(before, at: date)
        if before.phase == .relearning, let due = before.nextReviewAt, due > date { throw ReviewCardSchedulingError.relearningNotDue }
        let bucket = try before.relearningBucket(at: clock)
        let isRepeat = before.phase == .relearning && !bucket.isNew
        guard !isRepeat || bucket.repeats < Self.maximumDailyRepeats else { throw ReviewCardSchedulingError.relearningLimitReached }
        var after = before
        after.relearningDayKey = bucket.day.key
        after.relearningTimeZoneID = bucket.day.timeZoneID
        after.relearningRepeatCount = bucket.repeats + (isRepeat ? 1 : 0)
        if after.phase == .new, after.introducedAt == nil { after.introducedAt = clock.observedAt }
        try after.validate()
        return .init(before: before, after: after, clock: clock, isRelearningRepeat: isRepeat)
    }

    public func feedback(_ feedback: ReviewFeedback, for before: ReviewCardSchedule, at date: Date,
                         studyTimeZoneID: String, lastInteractionAt: Date? = nil) throws -> ReviewCardFeedbackPlan {
        let clock = try before.studyClock(at: date, timeZoneID: studyTimeZoneID, lastInteractionAt: lastInteractionAt)
        try requireEnabled(before, at: date)
        let bucket = try before.relearningBucket(at: clock)
        var after = before
        // Only presentation rolls an existing bucket; answering across midnight is not a presentation.
        if after.relearningDayKey == nil {
            after.relearningDayKey = bucket.day.key
            after.relearningTimeZoneID = bucket.day.timeZoneID
            after.relearningRepeatCount = bucket.repeats
        }
        after.lastReviewedAt = clock.observedAt
        if let requested = after.priorityRequestedAt, requested <= clock.observedAt { after.priorityRequestedAt = nil }
        let delay: ReviewScheduleDelay
        let disposition: ReviewFeedbackDisposition

        if feedback == .again || (feedback == .hard && before.phase == .relearning) {
            if feedback == .again { after.lapseCount = try increment(before.lapseCount) }
            after.masteryLevel = .vague
            after.confidentStreak = 0
            if bucket.repeats >= Self.maximumDailyRepeats {
                after.phase = .review
                after.intervalDays = 1
                after.nextReviewAt = max(try clock.nextDayStart, bucket.day.end)
                delay = .calendarDays(1)
                disposition = .relearningLimitReached
            } else {
                after.phase = .relearning
                after.nextReviewAt = clock.effectiveAt.addingTimeInterval(Self.relearningDelay)
                delay = .minutes(10)
                disposition = .relearning
            }
        } else {
            let days: Int
            switch feedback {
            case .again: throw WordNoteSnapshotError.invalidValue
            case .hard:
                days = min(max(1, before.intervalDays / 2), 3)
                after.masteryLevel = .vague
                after.confidentStreak = 0
            case .good:
                days = before.phase == .relearning ? 1 : ReviewScheduler.goodIntervalDays(
                    currentIntervalDays: before.intervalDays, currentCorrectStreak: before.confidentStreak)
                after.masteryLevel = .familiar
                after.confidentStreak = try increment(before.confidentStreak)
            case .easy:
                days = before.phase == .relearning ? 2 : ReviewScheduler.easyIntervalDays(
                    currentIntervalDays: before.intervalDays, currentCorrectStreak: before.confidentStreak)
                after.masteryLevel = .mastered
                after.confidentStreak = try increment(before.confidentStreak)
            }
            after.phase = .review
            after.intervalDays = days
            after.nextReviewAt = try clock.addingCalendarDays(days)
            delay = .calendarDays(days)
            disposition = .reviewed
        }
        try after.validate()
        return .init(feedback: feedback, before: before, after: after, clock: clock, delay: delay, disposition: disposition)
    }

    private func increment(_ value: Int) throws -> Int {
        guard value < ReviewStateValidation.maximumCounter else { throw ReviewCardSchedulingError.counterLimit }
        return value + 1
    }

    private func requireEnabled(_ schedule: ReviewCardSchedule, at date: Date) throws {
        guard schedule.phase != .suspended else { throw ReviewCardSchedulingError.suspended }
        if let until = schedule.buriedUntil, until > date { throw ReviewCardSchedulingError.buried }
    }
}
