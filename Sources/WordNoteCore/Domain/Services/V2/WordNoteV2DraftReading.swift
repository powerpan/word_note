import Foundation

extension WordNoteV2ContentService {
    public func termDraftVersion(_ id: UUID) throws -> WordNoteDraftVersion<WordNoteTermEditValues> {
        try WordNoteWriteGate.check(context)
        guard !context.hasChanges else { throw WordNoteV2ContentError.unsavedChanges }
        let current = try term(id)
        let courseIDs = Set(try fetch(CourseLink.self).filter { $0.termID == id }.map(\.courseID))
        return WordNoteDraftVersion(WordNoteTermEditValues(
            termText: current.term, termType: current.termType, chineseMeaning: current.chineseMeaning ?? "",
            englishDefinition: current.englishDefinition ?? "", aiContextExplanation: current.aiContextExplanation ?? "",
            exampleSentence: current.exampleSentence ?? "", contextSentence: current.contextSentence ?? "",
            courseID: current.courseID, courseIDs: courseIDs, sourceType: current.sourceType,
            category: current.category, importance: current.importance, masteryLevel: current.masteryLevel
        ), revision: current.revision)
    }

    public func courseDraftVersion(_ id: UUID) throws -> WordNoteDraftVersion<WordNoteCourseEditValues> {
        try WordNoteWriteGate.check(context)
        guard !context.hasChanges else { throw WordNoteV2ContentError.unsavedChanges }
        let current = try course(id)
        return WordNoteDraftVersion(WordNoteCourseEditValues(
            courseName: current.courseName, courseCode: current.courseCode ?? "", instructor: current.instructor ?? "",
            semester: current.semester ?? "", description: current.courseDescription ?? ""
        ), revision: current.revision)
    }

    public func manualSourceDraftVersion(_ id: UUID) throws -> WordNoteDraftVersion<WordNoteManualSourceValues> {
        try WordNoteWriteGate.check(context)
        guard !context.hasChanges else { throw WordNoteV2ContentError.unsavedChanges }
        let source = try record(id)
        guard let queue = AnalysisQueueState(rawValue: source.queueStateRaw) else { throw WordNoteV2ContentError.invalidState }
        let blocked: String?
        if source.status == .completed || source.status == .ignored {
            blocked = "This input has already been handled. Your unsaved term has been kept."
        } else if queue == .queued || queue == .running {
            blocked = "Analysis is pending. The manual term draft cannot be rebased yet."
        } else {
            blocked = nil
        }
        return WordNoteDraftVersion(WordNoteManualSourceValues(source), revision: source.revision, blockingMessage: blocked)
    }
}
