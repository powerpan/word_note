import Foundation

public enum InputType: String, Codable, CaseIterable, Identifiable {
    case word
    case phrase
    case sentence
    case paragraph
    case unknown

    public var id: String { rawValue }
}

public enum InputRecordStatus: String, Codable, CaseIterable, Identifiable {
    case draft
    case analyzing
    case analyzed
    case completed
    case failed
    case ignored

    public var id: String { rawValue }
}

public enum CandidateStatus: String, Codable, CaseIterable, Identifiable {
    case pending
    case saved
    case ignored

    public var id: String { rawValue }
}

public enum TermType: String, Codable, CaseIterable, Identifiable {
    case word
    case phrase
    case expression
    case sentencePattern

    public var id: String { rawValue }
}

public enum SourceType: String, Codable, CaseIterable, Identifiable {
    case `class`
    case paper
    case slides
    case assignment
    case book
    case other

    public var id: String { rawValue }
}

public enum Importance: String, Codable, CaseIterable, Identifiable, Comparable {
    case low
    case medium
    case high

    public var id: String { rawValue }

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

public enum TermCategory: String, Codable, CaseIterable, Identifiable {
    case general
    case academic
    case aiML
    case dl
    case nlp
    case cv
    case math
    case programming

    public var id: String { rawValue }
}

public enum MasteryLevel: String, Codable, CaseIterable, Identifiable {
    case new
    case vague
    case familiar
    case mastered

    public var id: String { rawValue }
}

public enum ReviewMode: String, Codable, CaseIterable, Identifiable {
    case englishToChinese
    case chineseToEnglish
    case contextCloze

    public var id: String { rawValue }
}

public enum ReviewFeedback: String, Codable, CaseIterable, Identifiable {
    case again
    case hard
    case good
    case easy

    public var id: String { rawValue }
}
