import Foundation
import SwiftData

extension WordNoteSchemaV3 {
    @Model
    public final class ReviewSessionItemModel {
        @Attribute(.unique) public var id: UUID
        public var sessionID: UUID
        public var cardID: UUID?
        public var originalCardID: UUID
        public var position: Int
        public var statusRaw: String = "pending"
        public var attemptCount: Int = 0
        public var availableAt: Date? = nil
        public var lastActionID: UUID? = nil
        public var completionOutcomeRaw: String? = nil
        public var createdAt: Date
        public var updatedAt: Date

        public init(id: UUID = UUID(), sessionID: UUID, cardID: UUID, position: Int, createdAt: Date = Date()) {
            self.id = id
            self.sessionID = sessionID
            self.cardID = cardID
            self.originalCardID = cardID
            self.position = position
            self.createdAt = createdAt
            self.updatedAt = createdAt
        }
    }
}
