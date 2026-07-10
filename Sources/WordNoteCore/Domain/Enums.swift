import Foundation

public enum InputType: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case word
    case phrase
    case sentence
    case paragraph
    case unknown

    public var id: String { rawValue }
}

public enum InputRecordStatus: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case draft
    case analyzing
    case analyzed
    case completed
    case failed
    case ignored

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .draft:
            return "Draft"
        case .analyzing:
            return "Analyzing"
        case .analyzed:
            return "Analyzed"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .ignored:
            return "Ignored"
        }
    }
}

public enum CandidateStatus: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case pending
    case saved
    case ignored

    public var id: String { rawValue }
}

public enum TermType: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case word
    case phrase
    case expression
    case sentencePattern

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .word:
            return "Word"
        case .phrase:
            return "Phrase"
        case .expression:
            return "Expression"
        case .sentencePattern:
            return "Sentence Pattern"
        }
    }
}

public enum SourceType: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case `class`
    case paper
    case slides
    case assignment
    case book
    case other

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .class:
            return "Class"
        case .paper:
            return "Paper"
        case .slides:
            return "Slides"
        case .assignment:
            return "Assignment"
        case .book:
            return "Book"
        case .other:
            return "Other"
        }
    }
}

public enum Importance: String, Codable, CaseIterable, Identifiable, Comparable, Hashable, Sendable {
    case low
    case medium
    case high

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        }
    }

    public static func < (lhs: Importance, rhs: Importance) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .low:
            return 0
        case .medium:
            return 1
        case .high:
            return 2
        }
    }
}

public enum TermCategory: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case general
    case academic
    case aiML
    case dl
    case nlp
    case cv
    case math
    case programming

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .general:
            return "General"
        case .academic:
            return "Academic"
        case .aiML:
            return "AI/ML"
        case .dl:
            return "DL"
        case .nlp:
            return "NLP"
        case .cv:
            return "CV"
        case .math:
            return "Math"
        case .programming:
            return "Programming"
        }
    }
}

public enum MasteryLevel: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case new
    case vague
    case familiar
    case mastered

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .new:
            return "New"
        case .vague:
            return "Vague"
        case .familiar:
            return "Familiar"
        case .mastered:
            return "Mastered"
        }
    }
}

public enum ReviewMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case englishToChinese
    case chineseToEnglish
    case contextCloze

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .englishToChinese:
            return "English → Chinese"
        case .chineseToEnglish:
            return "Chinese → English"
        case .contextCloze:
            return "Context Cloze"
        }
    }
}

public enum ReviewFeedback: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case again
    case hard
    case good
    case easy

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .again:
            return "Again"
        case .hard:
            return "Hard"
        case .good:
            return "Good"
        case .easy:
            return "Easy"
        }
    }
}
