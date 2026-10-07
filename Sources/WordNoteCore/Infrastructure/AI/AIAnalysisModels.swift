import Foundation

public struct AIAnalysisRequest: Equatable, Sendable {
    public let rawText: String
    public let courseName: String?
    public let sourceType: SourceType
    public let userNote: String?
    public let preferredLanguage: String
    public let lookupDirection: LookupDirection

    public init(
        rawText: String,
        courseName: String? = nil,
        sourceType: SourceType = .other,
        userNote: String? = nil,
        preferredLanguage: String = "Traditional Chinese",
        lookupDirection: LookupDirection? = nil
    ) {
        self.rawText = rawText
        self.courseName = courseName
        self.sourceType = sourceType
        self.userNote = userNote
        self.preferredLanguage = preferredLanguage
        self.lookupDirection = lookupDirection ?? LookupDirectionDetector.detect(rawText)
    }
}

public struct AIAnalysisResult: Equatable, Sendable {
    public let inputType: InputType
    public let sentenceMeaning: String?
    public let candidates: [AIAnalysisCandidate]
    public let model: String
    public let rawResponseID: String?

    public init(
        inputType: InputType,
        sentenceMeaning: String?,
        candidates: [AIAnalysisCandidate],
        model: String,
        rawResponseID: String?
    ) {
        self.inputType = inputType
        self.sentenceMeaning = sentenceMeaning
        self.candidates = candidates
        self.model = model
        self.rawResponseID = rawResponseID
    }
}

public struct AIAnalysisCandidate: Equatable, Sendable {
    public let term: String
    public let termType: TermType
    public let needToLearn: Bool
    public let importance: Importance
    public let category: TermCategory
    public let reason: String?
    public let chineseMeaning: String?
    public let englishDefinition: String?
    public let aiContextExplanation: String?
    public let exampleSentence: String?
    public let relatedTerms: [String]
    public let confidence: Double
    public let shouldAutoSelect: Bool

    public init(
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
        shouldAutoSelect: Bool = false
    ) {
        self.term = term
        self.termType = termType
        self.needToLearn = needToLearn
        self.importance = importance
        self.category = category
        self.reason = reason
        self.chineseMeaning = chineseMeaning
        self.englishDefinition = englishDefinition
        self.aiContextExplanation = aiContextExplanation
        self.exampleSentence = exampleSentence
        self.relatedTerms = relatedTerms
        self.confidence = confidence
        self.shouldAutoSelect = shouldAutoSelect
    }
}

public enum AIAnalysisError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidURL
    case network(String)
    case timeout
    case rateLimited
    case server(statusCode: Int, summary: String)
    case emptyResponse
    case invalidResponse
    case schemaMismatch(String)
    case inputTooLong(maxCharacters: Int)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "DeepSeek API key is missing."
        case .invalidURL:
            return "DeepSeek API URL is invalid."
        case .network(let summary):
            return "Network error: \(summary)"
        case .timeout:
            return "DeepSeek request timed out."
        case .rateLimited:
            return "DeepSeek rate limit reached. Try again later."
        case .server(let statusCode, let summary):
            return "DeepSeek server error \(statusCode): \(summary)"
        case .emptyResponse:
            return "DeepSeek returned an empty response."
        case .invalidResponse:
            return "DeepSeek returned an invalid response."
        case .schemaMismatch(let summary):
            return "AI JSON schema mismatch: \(summary)"
        case .inputTooLong(let maxCharacters):
            return "Input is too long for AI analysis. Keep it under \(maxCharacters) characters."
        }
    }
}
