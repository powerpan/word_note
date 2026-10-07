import Foundation
import SwiftData

extension WordNoteSchemaV2 {
    @Model
    public final class LookupEventModel {
        @Attribute(.unique) public var id: UUID
        public var termID: UUID
        public var captureID: UUID
        public var occurrenceID: UUID?
        public var occurredAt: Date
        public var kindRaw: String
        public var createdAt: Date

        public init(
            id: UUID = UUID(), termID: UUID, captureID: UUID, occurrenceID: UUID? = nil,
            occurredAt: Date, kind: LookupEventKind = .exactRepeat, createdAt: Date = Date()
        ) {
            self.id = id
            self.termID = termID
            self.captureID = captureID
            self.occurrenceID = occurrenceID
            self.occurredAt = occurredAt
            self.kindRaw = kind.rawValue
            self.createdAt = createdAt
        }
    }
}
