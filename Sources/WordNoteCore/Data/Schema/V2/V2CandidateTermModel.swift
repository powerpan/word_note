import Foundation
import SwiftData

extension WordNoteSchemaV2 {
    @Model
    public final class CandidateTermModel {
        @Attribute(.unique) public var id: UUID
        public var revision: Int = 0
        public var savedTermID: UUID? = nil
        public var savedLinkStateRaw: String = "none"
        public var confirmationOperationID: UUID? = nil
        public var analysisGeneration: Int = 0
        public var inputRecordID: UUID
        public var term: String
        public var normalizedTerm: String
        public var termTypeRaw: String
        public var needToLearn: Bool
        public var importanceRaw: String
        public var categoryRaw: String
        public var reason: String?
        public var chineseMeaning: String?
        public var englishDefinition: String?
        public var aiContextExplanation: String?
        public var exampleSentence: String?
        public var relatedTerms: [String]
        public var confidence: Double
        public var statusRaw: String
        public var createdAt: Date
        public var updatedAt: Date

        public var termType: TermType {
            get { TermType(rawValue: termTypeRaw) ?? .word }
            set { termTypeRaw = newValue.rawValue }
        }

        public var importance: Importance {
            get { Importance(rawValue: importanceRaw) ?? .medium }
            set { importanceRaw = newValue.rawValue }
        }

        public var category: TermCategory {
            get { TermCategory(rawValue: categoryRaw) ?? .general }
            set { categoryRaw = newValue.rawValue }
        }

        public var status: CandidateStatus {
            get { CandidateStatus(rawValue: statusRaw) ?? .pending }
            set { statusRaw = newValue.rawValue }
        }

        public init(
            id: UUID = UUID(),
            inputRecordID: UUID,
            term: String,
            termType: TermType,
            needToLearn: Bool,
            importance: Importance,
            category: TermCategory,
            reason: String? = nil,
            chineseMeaning: String? = nil,
            englishDefinition: String? = nil,
            aiContextExplanation: String? = nil,
            exampleSentence: String? = nil,
            relatedTerms: [String] = [],
            confidence: Double = 0,
            status: CandidateStatus = .pending,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.inputRecordID = inputRecordID
            self.term = term
            self.normalizedTerm = TextNormalizer.normalized(term)
            self.termTypeRaw = termType.rawValue
            self.needToLearn = needToLearn
            self.importanceRaw = importance.rawValue
            self.categoryRaw = category.rawValue
            self.reason = reason
            self.chineseMeaning = chineseMeaning
            self.englishDefinition = englishDefinition
            self.aiContextExplanation = aiContextExplanation
            self.exampleSentence = exampleSentence
            self.relatedTerms = relatedTerms
            self.confidence = confidence
            self.statusRaw = status.rawValue
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }
}
