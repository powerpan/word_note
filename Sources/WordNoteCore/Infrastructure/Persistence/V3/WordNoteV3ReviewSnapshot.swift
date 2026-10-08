import Foundation

public extension WordNoteSnapshotV3Payload {
    struct TermHistory: Codable, Equatable, Sendable {
        public var id: UUID
        public var legacyWrongCount: Int?
        public var legacyReviewCount: Int?
        public var legacyDuplicateHitCount: Int?
        public var legacySnapshotAt: Date?
    }

    struct Card: Codable, Equatable, Sendable {
        public var id: UUID
        public var termID: UUID
        public var mode: ReviewMode
        public var contentScopeKey: String
        public var schedule: ReviewCardSchedule
        public var clozeTarget: ReviewClozeTarget?
        public var revision: Int
        public var schedulerVersion: String
        public var createdAt: Date
        public var updatedAt: Date
    }

    struct Session: Codable, Equatable, Sendable {
        public var id: UUID
        public var scope: ReviewSessionScopeSnapshot
        public var targetCardCount: Int
        public var newCardLimitSnapshot: Int
        public var status: ReviewSessionStatus
        public var currentItemID: UUID?
        public var createdAt: Date
        public var updatedAt: Date
        public var endedAt: Date?
        public var revision: Int
        public var introductions: [ReviewNewCardIntroduction]? = nil
    }

    struct SessionItem: Codable, Equatable, Sendable {
        public var id: UUID
        public var sessionID: UUID
        public var cardID: UUID?
        public var originalCardID: UUID
        public var position: Int
        public var status: ReviewSessionItemStatus
        public var attemptCount: Int
        public var availableAt: Date?
        public var lastActionID: UUID?
        public var completionOutcome: ReviewCompletionOutcome?
        public var createdAt: Date
        public var updatedAt: Date
    }

    struct EventState: Codable, Equatable, Sendable {
        public var id: UUID
        public var cardID: UUID?
        public var originalCardID: UUID?
        public var sessionID: UUID?
        public var actionID: UUID?
        public var feedbackSemanticsVersion: Int
        public var schedulerVersion: String
        public var studyDayKey: String?
        public var studyTimeZoneID: String?
        public var beforeSchedule: ReviewCardSchedule?
        public var afterSchedule: ReviewCardSchedule?
        public var clockAnomaly: ReviewClockAnomaly?
        public var invalidatedAt: Date?
    }
}

enum ReviewPersistenceJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ value: String, as type: T.Type = T.self) throws -> T {
        guard value.utf8.count <= WordNoteSnapshotV3Codec.maximumDocumentBytes else { throw WordNoteSnapshotError.sizeLimit }
        do { return try JSONDecoder().decode(type, from: Data(value.utf8)) }
        catch { throw WordNoteSnapshotError.invalidDocument }
    }
}
