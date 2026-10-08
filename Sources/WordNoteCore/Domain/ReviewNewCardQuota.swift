import Foundation

public struct ReviewNewCardIntroduction: Codable, Equatable, Sendable {
    public var originalCardID: UUID
    public var introducedAt: Date
    public var chargedAt: Date
    public var studyDayKey: String
    public var studyTimeZoneID: String
}

public struct ReviewNewCardQuota: Equatable, Sendable {
    public let limit: Int
    public let used: Int
    public var remaining: Int { max(0, limit - used) }
    public let studyDayKey: String
    public let studyTimeZoneID: String
    public let resetsAt: Date
    public let observedAt: Date
    public let effectiveAt: Date

    init(payload: WordNoteSnapshotV3Payload, limit: Int, at date: Date, timeZoneID: String) throws {
        guard (0...50).contains(limit) else { throw WordNoteSnapshotError.invalidValue }
        try ReviewStateValidation.date(date)
        var day = try ReviewStudyDay(containing: date, timeZoneID: timeZoneID)
        var entries = payload.sessions.flatMap { $0.introductions ?? [] }
        let recorded = Set(entries.map(\.originalCardID))
        // Pre-B05 isolated snapshots have no ledger. Count surviving cards without inventing persisted history.
        for card in payload.cards where !recorded.contains(card.id) {
            guard let introduced = card.schedule.introducedAt else { continue }
            let originalZone = card.schedule.relearningTimeZoneID ?? timeZoneID
            let originalDay = try ReviewStudyDay(containing: introduced, timeZoneID: originalZone)
            entries.append(.init(originalCardID: card.id, introducedAt: introduced, chargedAt: introduced,
                studyDayKey: originalDay.key, studyTimeZoneID: originalZone))
        }
        let latest = entries.max { ($0.chargedAt, $0.originalCardID.uuidString) < ($1.chargedAt, $1.originalCardID.uuidString) }
        if let latest {
            let original = try ReviewStudyDay(key: latest.studyDayKey, timeZoneID: latest.studyTimeZoneID)
            if date < original.end { day = original }
        }
        self.limit = limit
        used = Set(entries.filter { $0.chargedAt >= day.start && $0.chargedAt < day.end }.map(\.originalCardID)).count
        studyDayKey = day.key
        studyTimeZoneID = day.timeZoneID
        resetsAt = day.end
        observedAt = date
        effectiveAt = max(date, latest?.chargedAt ?? date)
    }

    func introduction(cardID: UUID) -> ReviewNewCardIntroduction {
        .init(originalCardID: cardID, introducedAt: observedAt, chargedAt: effectiveAt,
              studyDayKey: studyDayKey, studyTimeZoneID: studyTimeZoneID)
    }
}
