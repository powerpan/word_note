import Foundation
import SwiftData

extension WordNoteSchemaV3 {
    @Model
    public final class ReviewCardModel {
        @Attribute(.unique) public var id: UUID
        public var termID: UUID
        public var modeRaw: String
        public var contentScopeKey: String = "wholeTerm"
        public var phaseRaw: String = "new"
        public var masteryLevelRaw: String = "new"
        public var intervalDays: Int = 0
        public var confidentStreak: Int = 0
        public var lapseCount: Int = 0
        public var nextReviewAt: Date? = nil
        public var priorityRequestedAt: Date? = nil
        public var introducedAt: Date? = nil
        public var lastReviewedAt: Date? = nil
        public var relearningDayKey: String? = nil
        public var relearningTimeZoneID: String? = nil
        public var relearningRepeatCount: Int = 0
        public var buriedUntil: Date? = nil
        public var clozeTargetJSON: String? = nil
        public var revision: Int = 0
        public var schedulerVersion: String = "simple-v2"
        public var createdAt: Date
        public var updatedAt: Date

        public init(id: UUID = UUID(), termID: UUID, mode: ReviewMode = .englishToChinese, createdAt: Date = Date()) {
            self.id = id
            self.termID = termID
            self.modeRaw = mode.rawValue
            self.createdAt = createdAt
            self.updatedAt = createdAt
        }
    }
}
