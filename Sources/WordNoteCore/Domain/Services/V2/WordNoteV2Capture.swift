import Foundation

public struct WordNoteCaptureRequest: Equatable, Sendable {
    public let captureID: UUID
    public let rawText: String
    public let courseID: UUID?
    public let sourceType: SourceType
    public let note: String?
    public let intent: LookupIntent
    public let capturedVia: CaptureSurface

    public init(
        captureID: UUID = UUID(), rawText: String, courseID: UUID? = nil,
        sourceType: SourceType = .other, note: String? = nil, intent: LookupIntent = .auto,
        capturedVia: CaptureSurface = .mainQuickAdd
    ) {
        self.captureID = captureID
        self.rawText = rawText
        self.courseID = courseID
        self.sourceType = sourceType
        self.note = note
        self.intent = intent
        self.capturedVia = capturedVia
    }
}

public struct WordNoteCaptureResult: Equatable, Sendable {
    public enum Destination: Equatable, Sendable {
        case inputRecord(id: UUID, queueState: AnalysisQueueState)
        case vocabulary(id: UUID, term: String, chineseMeaning: String?, englishDefinition: String?)
    }

    public let captureID: UUID
    public let destination: Destination
    public let isReplay: Bool
}

extension WordNoteV2ContentService {
    /// Saves synchronously, but never waits for or starts a network request.
    public func capture(
        _ request: WordNoteCaptureRequest, analyze: Bool = true, at date: Date = Date()
    ) throws -> WordNoteCaptureResult {
        try transaction {
            try validateDate(date)
            try validateText([request.rawText, request.note])
            guard request.capturedVia != .legacy else { throw WordNoteV2ContentError.invalidValue }
            let text = request.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw InputRecordValidationError.blankRawText }
            let direction = request.intent.resolvedDirection(for: request.rawText)
            let note = optionalText(request.note)
            let records = try fetch(Record.self).filter { $0.captureID == request.captureID }
            let events = try fetch(LookupEvent.self).filter { $0.captureID == request.captureID }
            guard records.count <= 1, events.count <= 1, records.isEmpty || events.isEmpty else {
                throw WordNoteV2ContentError.invalidState
            }
            if let existing = records.first {
                guard existing.rawText == text, existing.courseID == request.courseID,
                      existing.sourceTypeRaw == request.sourceType.rawValue, existing.note == note,
                      existing.lookupIntentRaw == request.intent.rawValue,
                      existing.capturedViaRaw == request.capturedVia.rawValue else {
                    throw WordNoteV2ContentError.captureConflict
                }
                guard let queue = AnalysisQueueState(rawValue: existing.queueStateRaw) else { throw WordNoteV2ContentError.invalidState }
                return WordNoteCaptureResult(captureID: request.captureID, destination: .inputRecord(id: existing.id, queueState: queue), isReplay: true)
            }
            if let event = events.first {
                guard analyze, direction == .englishToChinese,
                      let sourceID = event.occurrenceID,
                      let source = try fetch(Occurrence.self).first(where: { $0.id == sourceID }),
                      source.rawTextSnapshot == text, source.note == note, source.courseID == request.courseID,
                      source.sourceTypeRaw == request.sourceType.rawValue, source.capturedViaRaw == request.capturedVia.rawValue,
                      source.termID == event.termID, source.captureID == event.captureID else {
                    throw WordNoteV2ContentError.captureConflict
                }
                return localResult(try term(event.termID), captureID: request.captureID, replay: true)
            }
            guard try !fetch(Occurrence.self).contains(where: { $0.captureID == request.captureID }) else {
                throw WordNoteV2ContentError.captureConflict
            }
            if let courseID = request.courseID { _ = try course(courseID) }
            if analyze, direction == .englishToChinese, LookupDirectionDetector.isEnglishVocabularyTerm(text) {
                let normalized = TextNormalizer.normalized(text)
                let matches = try fetch(Term.self).filter { $0.normalizedTerm == normalized }
                guard matches.count <= 1 else { throw WordNoteV2ContentError.ambiguousExactMatch }
                if let existing = matches.first {
                    let source = Occurrence(
                        termID: existing.id, captureID: request.captureID, rawTextSnapshot: text,
                        note: note, courseID: request.courseID, sourceType: request.sourceType,
                        occurredAt: date, capturedVia: request.capturedVia, createdAt: date
                    )
                    context.insert(source)
                    context.insert(LookupEvent(
                        termID: existing.id, captureID: request.captureID, occurrenceID: source.id,
                        occurredAt: date, createdAt: date
                    ))
                    if let courseID = request.courseID { _ = try addMembership(termID: existing.id, courseID: courseID, at: date) }
                    try applyLegacyRepeat(to: existing, at: date)
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
            return WordNoteCaptureResult(
                captureID: request.captureID, destination: .inputRecord(id: record.id, queueState: analyze ? .queued : .none), isReplay: false
            )
        }
    }

    private func localResult(_ term: Term, captureID: UUID, replay: Bool) -> WordNoteCaptureResult {
        WordNoteCaptureResult(
            captureID: captureID, destination: .vocabulary(
                id: term.id, term: term.term, chineseMeaning: term.chineseMeaning, englishDefinition: term.englishDefinition
            ), isReplay: replay
        )
    }

    private func applyLegacyRepeat(to term: Term, at date: Date) throws {
        guard term.counterSemanticsVersionRaw == "legacyMixed" else { throw WordNoteV2ContentError.invalidState }
        let previousHit = term.lastDuplicateHitAt
        term.duplicateHitCount = try increment(term.duplicateHitCount)
        if previousHit.map({ date.timeIntervalSince($0) >= 10 * 60 }) ?? true { term.wrongCount = try increment(term.wrongCount) }
        switch term.importance {
        case .low: term.importance = .medium
        case .medium, .high: term.importance = .high
        }
        if term.masteryLevel == .familiar || term.masteryLevel == .mastered { term.masteryLevel = .vague }
        term.correctStreak = 0
        term.nextReviewAt = date
        term.lastDuplicateHitAt = date
        try touch(term, at: date)
    }
}
