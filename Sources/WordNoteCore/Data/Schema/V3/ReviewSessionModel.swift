import Foundation
import SwiftData

extension WordNoteSchemaV3 {
    @Model
    public final class ReviewSessionModel {
        @Attribute(.unique) public var id: UUID
        public var scopeSnapshotJSON: String
        public var targetCardCount: Int
        public var newCardLimitSnapshot: Int
        public var introductionsJSON: String? = nil
        public var statusRaw: String = "paused"
        public var currentItemID: UUID? = nil
        public var createdAt: Date
        public var updatedAt: Date
        public var endedAt: Date? = nil
        public var revision: Int = 0

        public init(id: UUID = UUID(), scopeSnapshotJSON: String, targetCardCount: Int = 20,
                    newCardLimitSnapshot: Int = 10, createdAt: Date = Date()) {
            self.id = id
            self.scopeSnapshotJSON = scopeSnapshotJSON
            self.targetCardCount = targetCardCount
            self.newCardLimitSnapshot = newCardLimitSnapshot
            self.createdAt = createdAt
            self.updatedAt = createdAt
        }
    }
}
