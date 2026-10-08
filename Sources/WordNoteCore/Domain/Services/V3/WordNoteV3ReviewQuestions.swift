import Foundation

extension WordNoteV3ReviewService {
    public func questionFront(sessionID: UUID) throws -> ReviewQuestionFront {
        try content.transaction {
            let source = try currentSnapshot(sessionID: sessionID)
            return try questionFront(card: source.card, term: source.term)
        }
    }

    public func revealedQuestion(lease: WordNoteV3ReviewLease, typedAnswer: String = "") throws -> ReviewQuestionBack {
        try content.transaction {
            let owner = try WordNoteV3ReviewOwnership.require(lease, in: context)
            let source = try currentSnapshot(sessionID: lease.sessionID)
            guard owner.revealed == source else { throw WordNoteV3ReviewError.answerNotRevealed }
            try content.validateText([typedAnswer])
            return try ReviewQuestionContent.back(card: source.card, term: source.term,
                occurrence: questionOccurrence(card: source.card), typedAnswer: typedAnswer)
        }
    }

    func questionFront(card: Payload.Card, term: WordNoteSnapshotPayload.Term) throws -> ReviewQuestionFront {
        try ReviewQuestionContent.front(card: card, term: term, occurrence: questionOccurrence(card: card))
    }

    private func questionOccurrence(card: Payload.Card) throws -> WordNoteSnapshotV2Payload.Occurrence? {
        guard let id = card.clozeTarget?.occurrenceID else { return nil }
        return try content.fetch(WordNoteSchemaV3.TermOccurrenceModel.self).first { $0.id == id }.map { .init($0) }
    }
}
