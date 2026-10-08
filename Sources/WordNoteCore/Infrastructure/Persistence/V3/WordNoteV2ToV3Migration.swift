import CryptoKit
import Foundation

public enum WordNoteV2ToV3Migration {
    public struct Issue: Equatable, Sendable {
        public enum Kind: String, Sendable { case legacyClozeNeedsTarget }
        public let kind: Kind
        public let termID: UUID
        public let eventID: UUID
    }

    public enum MigrationError: LocalizedError, Equatable {
        case preflightFailed([Issue])

        public var errorDescription: String? {
            switch self {
            case .preflightFailed:
                "Some legacy cloze reviews have no saved answer range. The data cannot be upgraded automatically. Resolve the reported review targets before retrying."
            }
        }
    }

    public static func preflight(_ source: WordNoteSnapshotV2Payload) throws -> [Issue] {
        try source.validate()
        return latestEvents(source).values.compactMap { event in
            event.modeRaw == ReviewMode.contextCloze.rawValue
                ? Issue(kind: .legacyClozeNeedsTarget, termID: event.termID, eventID: event.id) : nil
        }.sorted { $0.termID.uuidString < $1.termID.uuidString }
    }

    /// Pure, offline conversion. The migration timestamp belongs to the caller's durable operation.
    public static func convert(_ source: WordNoteSnapshotV2Payload, at date: Date) throws -> WordNoteSnapshotV3Payload {
        guard date.timeIntervalSince1970.isFinite, abs(date.timeIntervalSince1970) < 100_000_000_000 else { throw WordNoteSnapshotError.invalidValue }
        let issues = try preflight(source)
        guard issues.isEmpty else { throw MigrationError.preflightFailed(issues) }
        let source = source.canonicalized
        let latest = latestEvents(source)
        let cards = try source.content.terms.map { term in
            let mode: ReviewMode = try latest[term.id].map { try snapshotEnum($0.modeRaw) } ?? .englishToChinese
            var schedule = ReviewCardSchedule()
            schedule.phase = term.nextReviewAt == nil ? .suspended : .review
            schedule.masteryLevel = try snapshotEnum(term.masteryLevelRaw)
            schedule.intervalDays = term.reviewIntervalDays
            schedule.confidentStreak = term.correctStreak
            schedule.nextReviewAt = term.nextReviewAt
            schedule.lastReviewedAt = term.lastReviewedAt
            // Mixed historical wrongCount cannot be reinterpreted as actual recall failures.
            return WordNoteSnapshotV3Payload.Card(id: primaryCardID(term.id), termID: term.id, mode: mode,
                contentScopeKey: "wholeTerm", schedule: schedule, clozeTarget: nil, revision: 0,
                schedulerVersion: ReviewSchedulerVersion.legacy, createdAt: date, updatedAt: date)
        }
        let cardByTerm = Dictionary(uniqueKeysWithValues: cards.map { ($0.termID, $0) })
        let result = WordNoteSnapshotV3Payload(content: source,
            termHistories: source.content.terms.map { .init(id: $0.id, legacyWrongCount: $0.wrongCount,
                legacyReviewCount: $0.reviewCount, legacyDuplicateHitCount: $0.duplicateHitCount, legacySnapshotAt: date) },
            cards: cards, sessions: [], sessionItems: [],
            eventStates: source.content.reviewEvents.map { event in
                let primary = cardByTerm[event.termID]
                return .init(id: event.id, cardID: primary?.mode.rawValue == event.modeRaw ? primary?.id : nil,
                    originalCardID: nil, sessionID: nil, actionID: nil, feedbackSemanticsVersion: 1,
                    schedulerVersion: ReviewSchedulerVersion.legacy, studyDayKey: nil, studyTimeZoneID: nil,
                    beforeSchedule: nil, afterSchedule: nil, clockAnomaly: nil, invalidatedAt: nil)
            }).canonicalized
        try result.validate()
        return result
    }

    private static func latestEvents(_ source: WordNoteSnapshotV2Payload) -> [UUID: WordNoteSnapshotPayload.ReviewEvent] {
        var result: [UUID: WordNoteSnapshotPayload.ReviewEvent] = [:]
        for event in source.content.reviewEvents {
            if let old = result[event.termID], (old.reviewedAt, old.id.uuidString) >= (event.reviewedAt, event.id.uuidString) { continue }
            result[event.termID] = event
        }
        return result
    }

    private static func primaryCardID(_ termID: UUID) -> UUID {
        let key = "wordnote/v2-to-v3/1|primary-card|\(termID.uuidString.lowercased())"
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
