import Foundation

extension WordNoteV3ContentService {
    /// Durable capture only. Exact English hits have no analysis job or network client.
    public func capture(_ request: WordNoteCaptureRequest, analyze: Bool = true, at date: Date = Date()) throws -> WordNoteCaptureResult {
        try transaction {
            try validateDate(date)
            try validateText([request.rawText, request.note])
            guard request.capturedVia != .legacy else { throw WordNoteV3ContentError.invalidValue }
            let text = request.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw InputRecordValidationError.blankRawText }
            let direction = request.intent.resolvedDirection(for: request.rawText)
            let note = optionalText(request.note)
            let records = try fetch(Record.self).filter { $0.captureID == request.captureID }
            let events = try fetch(LookupEvent.self).filter { $0.captureID == request.captureID }
            guard records.count <= 1, events.count <= 1, records.isEmpty || events.isEmpty else { throw WordNoteV3ContentError.invalidState }
            if let existing = records.first {
                guard existing.rawText == text, existing.courseID == request.courseID,
                      existing.sourceTypeRaw == request.sourceType.rawValue, existing.note == note,
                      existing.lookupIntentRaw == request.intent.rawValue, existing.capturedViaRaw == request.capturedVia.rawValue else {
                    throw WordNoteV3ContentError.captureConflict
                }
                guard let queue = AnalysisQueueState(rawValue: existing.queueStateRaw) else { throw WordNoteV3ContentError.invalidState }
                return .init(captureID: request.captureID, destination: .inputRecord(id: existing.id, queueState: queue), isReplay: true)
            }
            if let event = events.first {
                guard analyze, direction == .englishToChinese, let sourceID = event.occurrenceID,
                      let source = try fetch(Occurrence.self).first(where: { $0.id == sourceID }),
                      source.rawTextSnapshot == text, source.note == note, source.courseID == request.courseID,
                      source.sourceTypeRaw == request.sourceType.rawValue, source.capturedViaRaw == request.capturedVia.rawValue,
                      source.termID == event.termID, source.captureID == event.captureID else { throw WordNoteV3ContentError.captureConflict }
                return localResult(try term(event.termID), captureID: request.captureID, replay: true)
            }
            guard try !fetch(Occurrence.self).contains(where: { $0.captureID == request.captureID }) else { throw WordNoteV3ContentError.captureConflict }
            if let courseID = request.courseID { _ = try course(courseID) }
            if analyze, direction == .englishToChinese, LookupDirectionDetector.isEnglishVocabularyTerm(text) {
                let normalized = TextNormalizer.normalized(text)
                let matches = try fetch(Term.self).filter { $0.normalizedTerm == normalized }
                guard matches.count <= 1 else { throw WordNoteV3ContentError.ambiguousExactMatch }
                if let existing = matches.first {
                    let source = Occurrence(termID: existing.id, captureID: request.captureID, rawTextSnapshot: text,
                        note: note, courseID: request.courseID, sourceType: request.sourceType, occurredAt: date,
                        capturedVia: request.capturedVia, createdAt: date)
                    context.insert(source)
                    context.insert(LookupEvent(termID: existing.id, captureID: request.captureID, occurrenceID: source.id,
                        occurredAt: date, createdAt: date))
                    if let courseID = request.courseID { try addMembership(termID: existing.id, courseID: courseID, at: date) }
                    try requestReviewPriority(for: existing, at: date)
                    try touch(existing, at: date)
                    return localResult(existing, captureID: request.captureID, replay: false)
                }
            }
            if analyze, text.count > AIAnalysisService.maximumInputCharacters {
                throw AIAnalysisError.inputTooLong(maxCharacters: AIAnalysisService.maximumInputCharacters)
            }
            let record = Record(rawText: text, courseID: request.courseID, sourceType: request.sourceType, note: note, createdAt: date, updatedAt: date)
            record.captureID = request.captureID
            record.capturedViaRaw = request.capturedVia.rawValue
            record.lookupIntentRaw = request.intent.rawValue
            record.resolvedLookupDirectionRaw = direction.rawValue
            record.directionDetectorVersion = request.intent == .auto ? LookupDirectionDetectorV1.version : "explicit-v1"
            record.queueStateRaw = analyze ? "queued" : "none"
            record.analysisGeneration = analyze ? 1 : 0
            context.insert(record)
            return .init(captureID: request.captureID, destination: .inputRecord(id: record.id, queueState: analyze ? .queued : .none), isReplay: false)
        }
    }

    private func localResult(_ term: Term, captureID: UUID, replay: Bool) -> WordNoteCaptureResult {
        .init(captureID: captureID, destination: .vocabulary(id: term.id, term: term.term,
            chineseMeaning: term.chineseMeaning, englishDefinition: term.englishDefinition), isReplay: replay)
    }

    private func requestReviewPriority(for term: Term, at date: Date) throws {
        let cards = try fetch(Card.self).filter { $0.termID == term.id }
        if cards.isEmpty {
            let card = Card(termID: term.id, createdAt: date)
            card.priorityRequestedAt = date
            context.insert(card)
            return
        }
        let enabled = cards.filter { $0.phaseRaw != ReviewCardPhase.suspended.rawValue && $0.contentScopeKey == "wholeTerm" }
        let selected = enabled.first { $0.modeRaw == ReviewMode.englishToChinese.rawValue }
            ?? enabled.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }.first
        guard let selected else { return }
        selected.priorityRequestedAt = date
        selected.revision = try increment(selected.revision)
        selected.updatedAt = max(selected.updatedAt, date)
    }
}
