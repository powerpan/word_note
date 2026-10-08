import Foundation

public enum WordNoteV2ConfirmationPlanError: LocalizedError, Equatable {
    case emptySelection
    case invalidChoice
    case unresolvedConflicts
    case stalePlan

    public var errorDescription: String? {
        switch self {
        case .emptySelection: "Select at least one pending candidate."
        case .invalidChoice: "A confirmation choice no longer matches this preview. Refresh the preview."
        case .unresolvedConflicts: "Resolve every conflict before confirming."
        case .stalePlan: "The selected content changed. Refresh the preview before confirming; nothing was saved."
        }
    }
}

public enum WordNoteV2ConfirmationField: String, CaseIterable, Codable, Identifiable, Sendable {
    case chineseMeaning, englishDefinition, aiContextExplanation, exampleSentence

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .chineseMeaning: "Chinese Meaning"
        case .englishDefinition: "English Definition"
        case .aiContextExplanation: "Technical Meaning"
        case .exampleSentence: "Example"
        }
    }
}

/// Choices refer only to IDs in a frozen preview. No model is edited while choosing.
public struct WordNoteV2ConfirmationChoices: Equatable, Sendable {
    public var ignoredCandidateIDs: Set<UUID> = []
    public var groups: [String: Group] = [:]

    public struct Group: Equatable, Sendable {
        public var existingTermID: UUID?
        public var preferredCandidateID: UUID?
        public var fieldSources: [WordNoteV2ConfirmationField: UUID] = [:]
        public init() {}
    }

    public init() {}
}

public struct WordNoteV2ConfirmationContent: Codable, Equatable, Sendable {
    public let termTypeRaw: String
    public let categoryRaw: String
    public let importanceRaw: String
    public var chineseMeaning: String?
    public var englishDefinition: String?
    public var aiContextExplanation: String?
    public var exampleSentence: String?

    init(_ value: WordNoteSnapshotPayload.Candidate) {
        termTypeRaw = value.termTypeRaw
        categoryRaw = value.categoryRaw
        importanceRaw = value.importanceRaw
        chineseMeaning = Self.trim(value.chineseMeaning)
        englishDefinition = Self.trim(value.englishDefinition)
        aiContextExplanation = Self.trim(value.aiContextExplanation)
        exampleSentence = Self.trim(value.exampleSentence)
    }

    init(_ value: WordNoteSnapshotPayload.Term) {
        termTypeRaw = value.termTypeRaw
        categoryRaw = value.categoryRaw
        importanceRaw = value.importanceRaw
        chineseMeaning = Self.trim(value.chineseMeaning)
        englishDefinition = Self.trim(value.englishDefinition)
        aiContextExplanation = Self.trim(value.aiContextExplanation)
        exampleSentence = Self.trim(value.exampleSentence)
    }

    public subscript(field: WordNoteV2ConfirmationField) -> String? {
        get {
            switch field {
            case .chineseMeaning: chineseMeaning
            case .englishDefinition: englishDefinition
            case .aiContextExplanation: aiContextExplanation
            case .exampleSentence: exampleSentence
            }
        }
        set {
            switch field {
            case .chineseMeaning: chineseMeaning = Self.trim(newValue)
            case .englishDefinition: englishDefinition = Self.trim(newValue)
            case .aiContextExplanation: aiContextExplanation = Self.trim(newValue)
            case .exampleSentence: exampleSentence = Self.trim(newValue)
            }
        }
    }

    static func trim(_ value: String?) -> String? {
        let result = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return result?.isEmpty == true ? nil : result
    }
}

public struct WordNoteV2ConfirmationPlan: Sendable, Identifiable {
    public let operationID: UUID
    public var id: UUID { operationID }
    public let groups: [Group]
    let records: [Record]
    let courses: [Course]

    public func sourceText(for candidateID: UUID) -> String? {
        guard let candidate = groups.flatMap(\.candidates).first(where: { $0.id == candidateID }) else { return nil }
        return records.first { $0.content.id == candidate.content.inputRecordID }?.content.rawText
    }

    public struct Candidate: Equatable, Sendable, Identifiable {
        public let content: WordNoteSnapshotPayload.Candidate
        public let state: WordNoteSnapshotV2Payload.CandidateState
        public var id: UUID { content.id }
        public var values: WordNoteV2ConfirmationContent { .init(content) }
    }

    public struct Target: Equatable, Sendable, Identifiable {
        public let content: WordNoteSnapshotPayload.Term
        public let state: WordNoteSnapshotV2Payload.TermState
        let occurrences: [WordNoteSnapshotV2Payload.Occurrence]
        let courseLinks: [WordNoteSnapshotV2Payload.CourseLink]
        public var id: UUID { content.id }
        public var values: WordNoteV2ConfirmationContent { .init(content) }
    }

    public struct Group: Sendable, Identifiable {
        public let id: String
        public let candidates: [Candidate]
        public let existingTerms: [Target]
        let proposedTermID: UUID
    }

    struct Record: Equatable, Sendable {
        let content: WordNoteSnapshotPayload.InputRecord
        let state: WordNoteSnapshotV2Payload.RecordState
    }

    struct Course: Equatable, Sendable {
        let content: WordNoteSnapshotPayload.Course
        let revision: Int
    }
}

public struct WordNoteV2ConfirmationResolution: Sendable {
    public let groups: [Group]
    public let conflicts: [Conflict]
    public let counts: Counts
    let ignoredCandidateIDs: [UUID]

    public struct Group: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let targetTermID: UUID
        public let isNew: Bool
        public let term: String
        public let candidateIDs: [UUID]
        public let primaryCandidateID: UUID
        public let content: WordNoteV2ConfirmationContent
        public let supplementedFields: [WordNoteV2ConfirmationField]
    }

    public struct Conflict: Equatable, Sendable, Identifiable {
        public let id: String
        public let message: String
    }

    public struct Counts: Equatable, Sendable {
        public let records: Int
        public let candidates: Int
        public let newTerms: Int
        /// Candidate links, including additional candidates linked to a new term in this batch.
        public let linkedCandidates: Int
        public let supplementedTerms: Int
        public let ignoredCandidates: Int
        public let unresolvedCandidates: Int
        public let conflicts: Int
    }
}

public struct WordNoteV2ConfirmationResult: Equatable, Sendable {
    public let termIDs: [UUID]
    public let counts: WordNoteV2ConfirmationResolution.Counts
    public let wasAlreadyApplied: Bool
}
