import Foundation
import SwiftData

@Model
public final class TermModel {
    @Attribute(.unique) public var id: UUID
    public var term: String
    public var normalizedTerm: String
    public var termTypeRaw: String
    public var chineseMeaning: String?
    public var englishDefinition: String?
    public var aiContextExplanation: String?
    public var exampleSentence: String?
    public var contextSentence: String?
    public var courseID: UUID?
    public var sourceRecordID: UUID?
    public var sourceTypeRaw: String
    public var tags: [String]
    public var categoryRaw: String
    public var importanceRaw: String
    public var masteryLevelRaw: String
    public var reviewCount: Int
    public var wrongCount: Int
    public var lastReviewedAt: Date?
    public var nextReviewAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public var termType: TermType {
        get { TermType(rawValue: termTypeRaw) ?? .word }
        set { termTypeRaw = newValue.rawValue }
    }

    public var sourceType: SourceType {
        get { SourceType(rawValue: sourceTypeRaw) ?? .other }
        set { sourceTypeRaw = newValue.rawValue }
    }

    public var category: TermCategory {
        get { TermCategory(rawValue: categoryRaw) ?? .general }
        set { categoryRaw = newValue.rawValue }
    }

    public var importance: Importance {
        get { Importance(rawValue: importanceRaw) ?? .medium }
        set { importanceRaw = newValue.rawValue }
    }

    public var masteryLevel: MasteryLevel {
        get { MasteryLevel(rawValue: masteryLevelRaw) ?? .new }
        set { masteryLevelRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        term: String,
        termType: TermType,
        chineseMeaning: String? = nil,
        englishDefinition: String? = nil,
        aiContextExplanation: String? = nil,
        exampleSentence: String? = nil,
        contextSentence: String? = nil,
        courseID: UUID? = nil,
        sourceRecordID: UUID? = nil,
        sourceType: SourceType = .other,
        tags: [String] = [],
        category: TermCategory = .general,
        importance: Importance = .medium,
        masteryLevel: MasteryLevel = .new,
        reviewCount: Int = 0,
        wrongCount: Int = 0,
        lastReviewedAt: Date? = nil,
        nextReviewAt: Date? = Date(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.term = term
        self.normalizedTerm = TextNormalizer.normalized(term)
        self.termTypeRaw = termType.rawValue
        self.chineseMeaning = chineseMeaning
        self.englishDefinition = englishDefinition
        self.aiContextExplanation = aiContextExplanation
        self.exampleSentence = exampleSentence
        self.contextSentence = contextSentence
        self.courseID = courseID
        self.sourceRecordID = sourceRecordID
        self.sourceTypeRaw = sourceType.rawValue
        self.tags = tags
        self.categoryRaw = category.rawValue
        self.importanceRaw = importance.rawValue
        self.masteryLevelRaw = masteryLevel.rawValue
        self.reviewCount = reviewCount
        self.wrongCount = wrongCount
        self.lastReviewedAt = lastReviewedAt
        self.nextReviewAt = nextReviewAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func applyReview(_ result: ReviewScheduleResult, reviewedAt: Date = Date()) {
        reviewCount += 1
        if result.countsAsWrong {
            wrongCount += 1
        }
        masteryLevel = result.masteryLevel
        lastReviewedAt = reviewedAt
        nextReviewAt = result.nextReviewAt
        touch(reviewedAt)
    }

    public func touch(_ date: Date = Date()) {
        updatedAt = date
    }
}
