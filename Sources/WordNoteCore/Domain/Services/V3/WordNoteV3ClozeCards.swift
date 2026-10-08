import Foundation

public struct WordNoteV3ClozeDraft: Equatable, Sendable {
    public let cardID: UUID
    public let preview: ReviewClozePreview
    let term: WordNoteSnapshotPayload.Term
    let termState: WordNoteSnapshotV2Payload.TermState
    let occurrence: WordNoteSnapshotV2Payload.Occurrence
    let record: WordNoteSnapshotPayload.InputRecord
    let recordState: WordNoteSnapshotV2Payload.RecordState
}

extension WordNoteV3ContentService {
    public func clozeSuggestions(termID: UUID, occurrenceID: UUID) throws -> [ReviewTextRange] {
        try transaction {
            let source = try verifiedClozeSource(termID: termID, occurrenceID: occurrenceID)
            return try ReviewClozeBuilder.suggestedRanges(term: term(termID).term, source: source.occurrence.rawTextSnapshot)
        }
    }

    public func previewClozeCard(termID: UUID, occurrenceID: UUID, selectedRange: ReviewTextRange,
                                 acceptedAnswers: [String] = [], cardID: UUID = UUID(), targetID: UUID = UUID()) throws -> WordNoteV3ClozeDraft {
        try transaction {
            let source = try verifiedClozeSource(termID: termID, occurrenceID: occurrenceID)
            let term = try term(termID)
            let preview = try ReviewClozeBuilder.preview(id: targetID, occurrenceID: occurrenceID,
                source: source.occurrence.rawTextSnapshot, term: term.term, selectedRange: selectedRange, acceptedAnswers: acceptedAnswers)
            return .init(cardID: cardID, preview: preview, term: .init(term), termState: .init(term),
                occurrence: source.occurrence, record: source.record, recordState: source.state)
        }
    }

    public func createClozeCard(_ draft: WordNoteV3ClozeDraft, studyTimeZoneID: String,
                               at date: Date = Date()) throws -> WordNoteSnapshotV3Payload.Card {
        try transaction {
            let cards = try fetch(Card.self)
            if let model = cards.first(where: { $0.id == draft.cardID }) {
                let saved = try WordNoteSnapshotV3Payload.Card(model)
                guard saved.termID == draft.term.id, saved.mode == .contextCloze,
                      saved.clozeTarget == draft.preview.target else { throw WordNoteV3ReviewError.actionConflict }
                return saved
            }
            let term = try term(draft.term.id)
            let source = try verifiedClozeSource(termID: term.id, occurrenceID: draft.occurrence.id)
            guard WordNoteSnapshotPayload.Term(term) == draft.term, WordNoteSnapshotV2Payload.TermState(term) == draft.termState,
                  source.occurrence == draft.occurrence, source.record == draft.record, source.state == draft.recordState,
                  WordNoteSnapshotV3Payload.sourceHash(source.occurrence.rawTextSnapshot) == draft.preview.target.sourceHash else {
                throw WordNoteV3ReviewError.stalePreview
            }
            let regenerated = try ReviewClozeBuilder.render(target: draft.preview.target, term: term.term, source: source.occurrence.rawTextSnapshot)
            guard regenerated == draft.preview else { throw WordNoteV3ReviewError.invalidPreview }
            guard try !cards.contains(where: { model in
                let existing = try WordNoteSnapshotV3Payload.Card(model)
                guard existing.termID == term.id, let target = existing.clozeTarget else { return false }
                return target.sourceDeletedAt == nil && target.sourceChangedAt == nil
                    && target.occurrenceID == draft.preview.target.occurrenceID
                    && target.startCharacterOffset == draft.preview.target.startCharacterOffset
                    && target.characterCount == draft.preview.target.characterCount
            }) else { throw WordNoteV3ReviewError.actionConflict }
            try validateDate(date)
            let model = Card(id: draft.cardID, termID: term.id, mode: .contextCloze, createdAt: date)
            model.contentScopeKey = draft.preview.target.contentScopeKey
            model.clozeTargetJSON = try ReviewPersistenceJSON.encode(draft.preview.target)
            model.buriedUntil = try reviewDirectionBurial(termID: term.id, at: date, studyTimeZoneID: studyTimeZoneID)
            context.insert(model)
            try touch(term, at: max(term.updatedAt, date))
            return try .init(model)
        }
    }

    /// An edited snapshot is no longer a byte-for-byte verified copy of its capture.
    public func reviseOccurrenceText(_ expected: WordNoteSnapshotV2Payload.Occurrence, expectedTermRevision: Int,
                                     rawText: String, at date: Date = Date()) throws {
        try transaction {
            try validateDate(date)
            try validateText([rawText])
            guard let model = try fetch(Occurrence.self).first(where: { $0.id == expected.id }) else { throw WordNoteV3ContentError.missingEntity }
            let term = try term(model.termID)
            try requireRevision(term.revision, expectedTermRevision)
            guard WordNoteSnapshotV2Payload.Occurrence(model) == expected,
                  model.rawTextSnapshot.utf8.elementsEqual(expected.rawTextSnapshot.utf8) else { throw WordNoteV3ReviewError.stalePreview }
            guard !model.rawTextSnapshot.utf8.elementsEqual(rawText.utf8) else { return }
            var affected = Set<UUID>()
            for card in try fetch(Card.self) where card.termID == model.termID {
                guard let json = card.clozeTargetJSON else { continue }
                var target: ReviewClozeTarget = try ReviewPersistenceJSON.decode(json)
                guard target.occurrenceID == model.id, target.sourceDeletedAt == nil else { continue }
                target.sourceChangedAt = date
                target.sourceHash = ""
                target.startCharacterOffset = 0
                target.characterCount = 0
                target.answer = ""
                target.acceptedAnswers = []
                card.clozeTargetJSON = try ReviewPersistenceJSON.encode(target)
                try suspend(card, at: max(card.updatedAt, date))
                affected.insert(card.id)
            }
            try invalidateSessionItems(for: affected, at: date)
            model.rawTextSnapshot = rawText
            try touch(term, at: max(term.updatedAt, date))
        }
    }

    private func verifiedClozeSource(termID: UUID, occurrenceID: UUID) throws ->
        (occurrence: WordNoteSnapshotV2Payload.Occurrence, record: WordNoteSnapshotPayload.InputRecord, state: WordNoteSnapshotV2Payload.RecordState) {
        guard let occurrence = try fetch(Occurrence.self).first(where: { $0.id == occurrenceID && $0.termID == termID }),
              let recordID = occurrence.sourceRecordID, let record = try fetch(Record.self).first(where: { $0.id == recordID }),
              record.resolvedLookupDirectionRaw == LookupDirection.englishToChinese.rawValue,
              record.rawText.utf8.elementsEqual(occurrence.rawTextSnapshot.utf8) else { throw ReviewQuestionError.invalidSource }
        return (.init(occurrence), .init(record), .init(record))
    }
}
