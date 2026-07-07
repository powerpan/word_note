import Foundation

public struct AIResponseParser {
    private let decoder: JSONDecoder

    public init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    public func parse(content: String, model: String, responseID: String?) throws -> AIAnalysisResult {
        let jsonString = stripCodeFence(from: content)
        guard let data = jsonString.data(using: .utf8) else {
            throw AIAnalysisError.invalidResponse
        }

        let payload: AIResponsePayload
        do {
            payload = try decoder.decode(AIResponsePayload.self, from: data)
        } catch {
            throw AIAnalysisError.schemaMismatch(error.localizedDescription)
        }

        let inputType = Self.mapInputType(payload.inputType)
        var seenTerms = Set<String>()
        let candidates = payload.items.compactMap { item -> AIAnalysisCandidate? in
            let term = item.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }

            let normalizedTerm = TextNormalizer.normalized(term)
            guard !seenTerms.contains(normalizedTerm) else { return nil }
            seenTerms.insert(normalizedTerm)

            return AIAnalysisCandidate(
                term: term,
                termType: Self.mapTermType(item.termType),
                needToLearn: item.needToLearn ?? false,
                importance: Self.mapImportance(item.importance),
                category: Self.mapCategory(item.category),
                reason: item.reason,
                chineseMeaning: item.chineseMeaning,
                englishDefinition: item.englishDefinition,
                aiContextExplanation: item.aiContextExplanation,
                exampleSentence: item.exampleSentence,
                relatedTerms: item.relatedTerms ?? [],
                confidence: min(max(item.confidence ?? 0, 0), 1),
                shouldAutoSelect: item.shouldAutoSelect ?? item.shouldAutoSave ?? false
            )
        }

        return AIAnalysisResult(
            inputType: inputType,
            sentenceMeaning: payload.sentenceMeaning,
            candidates: candidates,
            model: model,
            rawResponseID: responseID
        )
    }

    private func stripCodeFence(from content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }

        if let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }

        if let closingFence = text.range(of: "```", options: .backwards) {
            text = String(text[..<closingFence.lowerBound])
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mapInputType(_ value: String) -> InputType {
        switch normalizedEnumToken(value) {
        case "word":
            return .word
        case "phrase":
            return .phrase
        case "sentence":
            return .sentence
        case "paragraph":
            return .paragraph
        default:
            return .unknown
        }
    }

    private static func mapTermType(_ value: String?) -> TermType {
        switch normalizedEnumToken(value ?? "") {
        case "phrase":
            return .phrase
        case "expression":
            return .expression
        case "sentencepattern":
            return .sentencePattern
        default:
            return .word
        }
    }

    private static func mapImportance(_ value: String?) -> Importance {
        switch normalizedEnumToken(value ?? "") {
        case "high":
            return .high
        case "low":
            return .low
        default:
            return .medium
        }
    }

    private static func mapCategory(_ value: String?) -> TermCategory {
        switch normalizedEnumToken(value ?? "") {
        case "academic":
            return .academic
        case "aiml", "ai", "ml":
            return .aiML
        case "dl", "deeplearning":
            return .dl
        case "nlp":
            return .nlp
        case "cv", "computervision":
            return .cv
        case "math", "mathematics":
            return .math
        case "programming", "code", "coding":
            return .programming
        default:
            return .general
        }
    }

    private static func normalizedEnumToken(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

private struct AIResponsePayload: Decodable {
    let inputType: String
    let sentenceMeaning: String?
    let items: [AIResponseItem]

    private enum CodingKeys: String, CodingKey {
        case inputType = "input_type"
        case sentenceMeaning = "sentence_meaning"
        case items
    }
}

private struct AIResponseItem: Decodable {
    let term: String
    let termType: String?
    let needToLearn: Bool?
    let importance: String?
    let category: String?
    let reason: String?
    let chineseMeaning: String?
    let englishDefinition: String?
    let aiContextExplanation: String?
    let exampleSentence: String?
    let relatedTerms: [String]?
    let confidence: Double?
    let shouldAutoSelect: Bool?
    let shouldAutoSave: Bool?

    private enum CodingKeys: String, CodingKey {
        case term
        case termType = "term_type"
        case needToLearn = "need_to_learn"
        case importance
        case category
        case reason
        case chineseMeaning = "chinese_meaning"
        case englishDefinition = "english_definition"
        case aiContextExplanation = "ai_context_explanation"
        case exampleSentence = "example_sentence"
        case relatedTerms = "related_terms"
        case confidence
        case shouldAutoSelect = "should_auto_select"
        case shouldAutoSave = "should_auto_save"
    }
}
