import Foundation

public struct ReviewClozePreview: Equatable, Sendable {
    public let target: ReviewClozeTarget
    public let prompt: String
    public let hiddenRanges: [ReviewTextRange]
}

public enum ReviewClozeBuilder {
    public static func suggestedRanges(term: String, source: String) throws -> [ReviewTextRange] {
        try requireEnglishSource(source)
        return try ReviewTextMasking.ranges(in: source, forms: [term])
    }

    public static func preview(id: UUID = UUID(), occurrenceID: UUID, source: String, term: String,
                               selectedRange: ReviewTextRange, acceptedAnswers: [String] = []) throws -> ReviewClozePreview {
        try requireEnglishSource(source)
        let answer = try selectedRange.text(in: source)
        guard LookupDirectionDetector.isEnglishVocabularyTerm(answer),
              answer == answer.trimmingCharacters(in: .whitespacesAndNewlines),
              try ReviewTextMasking.ranges(in: source, forms: [answer]).contains(selectedRange),
              acceptedAnswers.count <= 100, acceptedAnswers.allSatisfy({
                  LookupDirectionDetector.isEnglishVocabularyTerm($0) && !TextNormalizer.isBlank($0)
              }) else { throw ReviewQuestionError.invalidRange }
        let target = ReviewClozeTarget(id: id, occurrenceID: occurrenceID, sourceHash: WordNoteSnapshotV3Payload.sourceHash(source),
            startCharacterOffset: selectedRange.start, characterCount: selectedRange.count,
            answer: answer, acceptedAnswers: acceptedAnswers)
        return try render(target: target, term: term, source: source)
    }

    public static func render(target: ReviewClozeTarget, term: String, source: String) throws -> ReviewClozePreview {
        guard target.sourceDeletedAt == nil, target.sourceChangedAt == nil,
              target.sourceHash == WordNoteSnapshotV3Payload.sourceHash(source) else { throw ReviewQuestionError.sourceChanged }
        try requireEnglishSource(source)
        let primary = ReviewTextRange(start: target.startCharacterOffset, count: target.characterCount)
        guard LookupDirectionDetector.isEnglishVocabularyTerm(term),
              LookupDirectionDetector.isEnglishVocabularyTerm(target.answer),
              target.acceptedAnswers.count <= 100,
              target.acceptedAnswers.allSatisfy({ LookupDirectionDetector.isEnglishVocabularyTerm($0) }),
              try primary.text(in: source) == target.answer,
              try ReviewTextMasking.ranges(in: source, forms: [target.answer]).contains(primary) else { throw ReviewQuestionError.invalidRange }
        let ranges = try ReviewTextMasking.ranges(in: source, forms: [term, target.answer] + target.acceptedAnswers)
        let prompt = try ReviewTextMasking.mask(source, ranges: ranges)
        guard LookupDirectionDetector.isEnglishVocabularyTerm(prompt) else { throw ReviewQuestionError.missingContext }
        return .init(target: target, prompt: prompt, hiddenRanges: ranges)
    }

    private static func requireEnglishSource(_ source: String) throws {
        guard LookupDirectionDetector.isEnglishVocabularyTerm(source), !LookupDirectionDetector.containsHan(source),
              source.count <= WordNoteSnapshotPayload.maximumTextCharacters else { throw ReviewQuestionError.invalidSource }
    }
}
