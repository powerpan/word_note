import Foundation
import SwiftData

extension WordNoteSchemaV2 {
    @Model
    public final class InputRecordModel {
        @Attribute(.unique) public var id: UUID
        public var captureID: UUID = UUID()
        public var lookupIntentRaw: String = "auto"
        public var resolvedLookupDirectionRaw: String = "englishToChinese"
        public var directionDetectorVersion: String = "han-latin-v1"
        public var analysisGeneration: Int = 0
        public var attemptID: UUID? = nil
        public var queueStateRaw: String = "none"
        public var autoRetryCount: Int = 0
        public var nextAttemptAt: Date? = nil
        public var revision: Int = 0
        public var rawText: String
        public var normalizedText: String
        public var inputTypeRaw: String
        public var statusRaw: String
        public var sentenceMeaning: String?
        public var courseID: UUID?
        public var sourceTypeRaw: String
        public var note: String?
        public var aiErrorSummary: String?
        public var analyzedAt: Date?
        public var createdAt: Date
        public var updatedAt: Date

        public var inputType: InputType {
            get { InputType(rawValue: inputTypeRaw) ?? .unknown }
            set { inputTypeRaw = newValue.rawValue }
        }

        public var status: InputRecordStatus {
            get { InputRecordStatus(rawValue: statusRaw) ?? .draft }
            set { statusRaw = newValue.rawValue }
        }

        public var sourceType: SourceType {
            get { SourceType(rawValue: sourceTypeRaw) ?? .other }
            set { sourceTypeRaw = newValue.rawValue }
        }

        public init(
            id: UUID = UUID(),
            rawText: String,
            inputType: InputType = .unknown,
            status: InputRecordStatus = .draft,
            sentenceMeaning: String? = nil,
            courseID: UUID? = nil,
            sourceType: SourceType = .other,
            note: String? = nil,
            aiErrorSummary: String? = nil,
            analyzedAt: Date? = nil,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.rawText = rawText
            self.resolvedLookupDirectionRaw = LookupDirectionDetectorV1.detect(rawText).rawValue
            self.normalizedText = TextNormalizer.normalized(rawText)
            self.inputTypeRaw = inputType.rawValue
            self.statusRaw = status.rawValue
            self.sentenceMeaning = sentenceMeaning
            self.courseID = courseID
            self.sourceTypeRaw = sourceType.rawValue
            self.note = note
            self.aiErrorSummary = aiErrorSummary
            self.analyzedAt = analyzedAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }
}
