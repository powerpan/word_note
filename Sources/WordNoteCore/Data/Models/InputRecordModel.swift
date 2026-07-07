import Foundation
import SwiftData

@Model
public final class InputRecordModel {
    @Attribute(.unique) public var id: UUID
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

    public func updateRawText(_ rawText: String, at date: Date = Date()) {
        self.rawText = rawText
        self.normalizedText = TextNormalizer.normalized(rawText)
        touch(date)
    }

    public func markAnalyzing(at date: Date = Date()) {
        status = .analyzing
        aiErrorSummary = nil
        touch(date)
    }

    public func markAnalyzed(sentenceMeaning: String?, inputType: InputType, at date: Date = Date()) {
        self.status = .analyzed
        self.sentenceMeaning = sentenceMeaning
        self.inputType = inputType
        self.analyzedAt = date
        self.aiErrorSummary = nil
        touch(date)
    }

    public func markFailed(_ summary: String, at date: Date = Date()) {
        status = .failed
        aiErrorSummary = summary
        touch(date)
    }

    public func touch(_ date: Date = Date()) {
        updatedAt = date
    }
}
