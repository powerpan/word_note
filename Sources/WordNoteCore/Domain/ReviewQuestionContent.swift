import Foundation

public enum ReviewTypedAnswerAssessment: Equatable, Sendable { case empty, matchesSavedAnswer, needsSelfAssessment }

public struct ReviewQuestionFront: Equatable, Sendable {
    public let cardID: UUID
    public let mode: ReviewMode
    public let prompt: String
    public var allowsTypedAnswer: Bool { mode != .englishToChinese }
}

public struct ReviewQuestionBack: Equatable, Sendable {
    public let englishTerm: String
    public let chineseMeaning: String?
    public let englishDefinition: String?
    public let technicalExplanation: String?
    public let example: String?
    public let originalText: String?
    public let answer: String
    public let acceptedAnswers: [String]
    public let typedAnswer: String
    public let assessment: ReviewTypedAnswerAssessment
}

public enum ReviewQuestionContent {
    public static func front(card: WordNoteSnapshotV3Payload.Card, term: WordNoteSnapshotPayload.Term,
                             occurrence: WordNoteSnapshotV2Payload.Occurrence? = nil) throws -> ReviewQuestionFront {
        guard card.termID == term.id, card.schedule.phase != .suspended,
              LookupDirectionDetector.isEnglishVocabularyTerm(term.term) else { throw ReviewQuestionError.missingAnswer }
        let prompt: String
        switch card.mode {
        case .englishToChinese:
            guard !TextNormalizer.isBlank(term.term),
                  !TextNormalizer.isBlank(term.chineseMeaning ?? "") || !TextNormalizer.isBlank(term.englishDefinition ?? "") else {
                throw ReviewQuestionError.missingAnswer
            }
            prompt = term.term
        case .chineseToEnglish:
            guard let meaning = term.chineseMeaning, LookupDirectionDetector.containsHan(meaning) else { throw ReviewQuestionError.missingAnswer }
            prompt = try ReviewTextMasking.mask(meaning, forms: [term.term])
        case .contextCloze:
            guard let target = card.clozeTarget, let occurrence, occurrence.id == target.occurrenceID,
                  occurrence.termID == term.id else { throw ReviewQuestionError.invalidSource }
            prompt = try ReviewClozeBuilder.render(target: target, term: term.term, source: occurrence.rawTextSnapshot).prompt
        }
        return .init(cardID: card.id, mode: card.mode, prompt: prompt)
    }

    public static func back(card: WordNoteSnapshotV3Payload.Card, term: WordNoteSnapshotPayload.Term,
                            occurrence: WordNoteSnapshotV2Payload.Occurrence? = nil, typedAnswer: String = "") throws -> ReviewQuestionBack {
        _ = try front(card: card, term: term, occurrence: occurrence)
        let answer: String
        switch card.mode {
        case .englishToChinese: answer = TextNormalizer.isBlank(term.chineseMeaning ?? "") ? (term.englishDefinition ?? "") : (term.chineseMeaning ?? "")
        case .chineseToEnglish: answer = term.term
        case .contextCloze: answer = card.clozeTarget!.answer
        }
        let accepted = card.mode == .contextCloze ? card.clozeTarget!.acceptedAnswers : []
        return .init(englishTerm: term.term, chineseMeaning: term.chineseMeaning, englishDefinition: term.englishDefinition,
            technicalExplanation: term.aiContextExplanation, example: term.exampleSentence,
            originalText: occurrence?.rawTextSnapshot, answer: answer, acceptedAnswers: accepted,
            typedAnswer: typedAnswer, assessment: assess(typedAnswer, acceptedAnswers: [answer] + accepted))
    }

    public static func assess(_ input: String, acceptedAnswers: [String]) -> ReviewTypedAnswerAssessment {
        let normalized = TextNormalizer.normalized(input.precomposedStringWithCanonicalMapping)
        guard !normalized.isEmpty else { return .empty }
        return acceptedAnswers.contains { TextNormalizer.normalized($0.precomposedStringWithCanonicalMapping) == normalized }
            ? .matchesSavedAnswer : .needsSelfAssessment
    }
}
