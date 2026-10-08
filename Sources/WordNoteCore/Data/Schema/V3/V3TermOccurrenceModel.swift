import Foundation
import SwiftData

extension WordNoteSchemaV3 {
    @Model
    public final class TermOccurrenceModel {
        @Attribute(.unique) public var id: UUID
        public var termID: UUID
        public var captureID: UUID
        public var sourceRecordID: UUID?
        public var rawTextSnapshot: String
        public var note: String?
        public var courseID: UUID?
        public var sourceTypeRaw: String
        public var occurredAt: Date
        public var capturedViaRaw: String
        public var legacy: Bool
        public var sourceTitle: String?
        public var sourceURL: String?
        public var sourcePage: String?
        public var createdAt: Date

        public init(
            id: UUID = UUID(), termID: UUID, captureID: UUID, sourceRecordID: UUID? = nil,
            rawTextSnapshot: String, note: String? = nil, courseID: UUID? = nil,
            sourceType: SourceType = .other, occurredAt: Date, capturedVia: CaptureSurface,
            legacy: Bool = false, sourceTitle: String? = nil, sourceURL: String? = nil,
            sourcePage: String? = nil, createdAt: Date = Date()
        ) {
            self.id = id
            self.termID = termID
            self.captureID = captureID
            self.sourceRecordID = sourceRecordID
            self.rawTextSnapshot = rawTextSnapshot
            self.note = note
            self.courseID = courseID
            self.sourceTypeRaw = sourceType.rawValue
            self.occurredAt = occurredAt
            self.capturedViaRaw = capturedVia.rawValue
            self.legacy = legacy
            self.sourceTitle = sourceTitle
            self.sourceURL = sourceURL
            self.sourcePage = sourcePage
            self.createdAt = createdAt
        }
    }
}
