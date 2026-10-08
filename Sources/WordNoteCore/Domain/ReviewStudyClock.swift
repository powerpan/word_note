import Foundation

public struct ReviewStudyClock: Equatable, Sendable {
    public let observedAt: Date
    public let effectiveAt: Date
    public let studyDayKey: String
    public let studyTimeZoneID: String
    public let anomaly: ReviewClockAnomaly?

    init(at date: Date, timeZoneID: String, notBefore: Date?) throws {
        try ReviewStateValidation.date(date)
        try ReviewStateValidation.date(notBefore)
        let day = try ReviewStudyDay(containing: date, timeZoneID: timeZoneID)
        observedAt = date
        effectiveAt = max(date, notBefore ?? date)
        studyDayKey = day.key
        studyTimeZoneID = timeZoneID
        anomaly = effectiveAt > date ? .movedBackward : nil
    }

    func addingCalendarDays(_ days: Int) throws -> Date {
        let calendar = try ReviewStudyDay.calendar(timeZoneID: studyTimeZoneID)
        guard let value = calendar.date(byAdding: .day, value: days, to: effectiveAt) else { throw WordNoteSnapshotError.invalidValue }
        try ReviewStateValidation.date(value)
        guard value > effectiveAt else { throw WordNoteSnapshotError.invalidValue }
        return value
    }

    var nextDayStart: Date {
        get throws { try ReviewStudyDay(containing: effectiveAt, timeZoneID: studyTimeZoneID).end }
    }
}

struct ReviewStudyDay {
    let key: String
    let timeZoneID: String
    let start: Date
    let end: Date

    init(containing date: Date, timeZoneID: String) throws {
        try ReviewStateValidation.date(date)
        let calendar = try Self.calendar(timeZoneID: timeZoneID)
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard parts.era == 1, let year = parts.year, let month = parts.month, let day = parts.day,
              (1...9999).contains(year), let interval = calendar.dateInterval(of: .day, for: date) else {
            throw WordNoteSnapshotError.invalidValue
        }
        key = String(format: "%04d-%02d-%02d", year, month, day)
        self.timeZoneID = timeZoneID
        start = interval.start
        end = interval.end
        try ReviewStateValidation.date(start)
        try ReviewStateValidation.date(end)
    }

    init(key: String, timeZoneID: String) throws {
        guard key.utf8.count == 10, key.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) else {
            throw WordNoteSnapshotError.invalidValue
        }
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]), (1...9999).contains(year) else {
            throw WordNoteSnapshotError.invalidValue
        }
        let calendar = try Self.calendar(timeZoneID: timeZoneID)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else {
            throw WordNoteSnapshotError.invalidValue
        }
        try self.init(containing: date, timeZoneID: timeZoneID)
        guard self.key == key else { throw WordNoteSnapshotError.invalidValue }
    }

    static func optional(key: String?, timeZoneID: String?, required: Bool) throws -> Self? {
        if key == nil, timeZoneID == nil, !required { return nil }
        guard let key, let timeZoneID else { throw WordNoteSnapshotError.invalidValue }
        return try Self(key: key, timeZoneID: timeZoneID)
    }

    static func calendar(timeZoneID: String) throws -> Calendar {
        guard let timeZone = TimeZone(identifier: timeZoneID) else { throw WordNoteSnapshotError.invalidValue }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }
}

extension ReviewCardSchedule {
    func studyClock(at date: Date, timeZoneID: String, lastInteractionAt: Date?) throws -> ReviewStudyClock {
        try validate()
        try ReviewStateValidation.date(lastInteractionAt)
        let bucket = try ReviewStudyDay.optional(key: relearningDayKey, timeZoneID: relearningTimeZoneID, required: false)
        let floor = [lastInteractionAt, lastReviewedAt, introducedAt, bucket?.start].compactMap { $0 }.max()
        return try ReviewStudyClock(at: date, timeZoneID: timeZoneID, notBefore: floor)
    }

    func relearningBucket(at clock: ReviewStudyClock) throws -> (day: ReviewStudyDay, repeats: Int, isNew: Bool) {
        if let old = try ReviewStudyDay.optional(key: relearningDayKey, timeZoneID: relearningTimeZoneID, required: false),
           clock.effectiveAt < old.end {
            // Keep the persisted day boundary across clock rollback and mid-day time-zone changes.
            return (old, relearningRepeatCount, false)
        }
        return (try ReviewStudyDay(containing: clock.effectiveAt, timeZoneID: clock.studyTimeZoneID), 0, true)
    }
}
