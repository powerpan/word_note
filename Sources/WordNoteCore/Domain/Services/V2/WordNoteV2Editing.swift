import Foundation

public struct WordNoteV2CandidateEdit: Equatable, Sendable {
    public let id: UUID
    public let revision: Int
    public let recordRevision: Int
    public var term: String
    public var importance: Importance
    public var category: TermCategory
    public var chineseMeaning: String
    public var englishDefinition: String
    public var aiContextExplanation: String
    public var exampleSentence: String

    @MainActor
    public init(_ candidate: WordNoteSchemaV2.CandidateTermModel, recordRevision: Int) {
        id = candidate.id
        revision = candidate.revision
        self.recordRevision = recordRevision
        term = candidate.term
        importance = candidate.importance
        category = candidate.category
        chineseMeaning = candidate.chineseMeaning ?? ""
        englishDefinition = candidate.englishDefinition ?? ""
        aiContextExplanation = candidate.aiContextExplanation ?? ""
        exampleSentence = candidate.exampleSentence ?? ""
    }
}

extension WordNoteV2ContentService {
    public func updateCourse(
        _ id: UUID, expectedRevision: Int, courseName: String, courseCode: String?,
        instructor: String?, semester: String?, description: String?, at date: Date = Date()
    ) throws {
        try undoableTransaction("Edit Course", scope: { .init(courses: [id]) }) {
            try validateDate(date)
            try validateText([courseName, courseCode, instructor, semester, description])
            guard let name = optionalText(courseName) else { throw CourseServiceError.blankCourseName }
            let value = try course(id)
            try requireRevision(value.revision, expectedRevision)
            value.courseName = name
            value.courseCode = optionalText(courseCode)
            value.instructor = optionalText(instructor)
            value.semester = optionalText(semester)
            value.courseDescription = optionalText(description)
            value.revision = try increment(value.revision)
            value.updatedAt = date
        }
    }

    public func updateTerm(
        _ id: UUID, expectedRevision: Int, termText: String, termType: TermType,
        chineseMeaning: String?, englishDefinition: String?, aiContextExplanation: String?,
        exampleSentence: String?, contextSentence: String?, courseIDs: Set<UUID>, sourceType: SourceType,
        category: TermCategory, importance: Importance, masteryLevel: MasteryLevel, at date: Date = Date()
    ) throws {
        try undoableTransaction("Edit Term", scope: { .init(terms: [id]) }) {
            try validateDate(date)
            try validateText([termText, chineseMeaning, englishDefinition, aiContextExplanation, exampleSentence, contextSentence])
            let value = try term(id)
            try requireRevision(value.revision, expectedRevision)
            let text = termText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard LookupDirectionDetector.isEnglishVocabularyTerm(text) else { throw VocabularyServiceError.englishTermRequired(text) }
            guard optionalText(chineseMeaning) != nil || optionalText(englishDefinition) != nil else {
                throw VocabularyServiceError.missingDefinition(text)
            }
            let normalized = TextNormalizer.normalized(text)
            guard try !fetch(Term.self).contains(where: { $0.id != id && $0.normalizedTerm == normalized }) else {
                throw VocabularyServiceError.duplicateTerm(text)
            }
            for courseID in courseIDs { _ = try course(courseID) }
            let links = try fetch(CourseLink.self).filter { $0.termID == id }
            for link in links where !courseIDs.contains(link.courseID) { context.delete(link) }
            for courseID in courseIDs { _ = try addMembership(termID: id, courseID: courseID, at: date) }
            value.term = text
            value.normalizedTerm = normalized
            value.termType = termType
            value.chineseMeaning = optionalText(chineseMeaning)
            value.englishDefinition = optionalText(englishDefinition)
            value.aiContextExplanation = optionalText(aiContextExplanation)
            value.exampleSentence = optionalText(exampleSentence)
            value.contextSentence = optionalText(contextSentence)
            value.sourceType = sourceType
            value.category = category
            value.importance = importance
            value.masteryLevel = masteryLevel
            // Original capture metadata and the legacy course snapshot are not membership authority.
            try touch(value, at: date)
        }
    }

    public func updateCandidate(_ edit: WordNoteV2CandidateEdit, at date: Date = Date()) throws {
        try updateCandidates([edit], at: date)
    }

    public func updateCandidates(_ edits: [WordNoteV2CandidateEdit], at date: Date = Date()) throws {
        try undoableTransaction("Edit Candidates", scope: { try undoScope(candidateIDs: Set(edits.map(\.id))) }) {
            try validateDate(date)
            guard Set(edits.map(\.id)).count == edits.count else { throw WordNoteV2ContentError.invalidValue }
            let storedCandidates = try fetch(Candidate.self)
            var sources: [UUID: Record] = [:]
            // Validate every original revision before advancing shared source records.
            for edit in edits {
                guard let value = storedCandidates.first(where: { $0.id == edit.id }) else {
                    throw WordNoteV2ContentError.missingEntity
                }
                try requireRevision(value.revision, edit.revision)
                guard value.status == .pending else { throw WordNoteV2ContentError.candidateAlreadyHandled }
                let source = try sources[value.inputRecordID] ?? record(value.inputRecordID)
                try requireRevision(source.revision, edit.recordRevision)
                try requireEditableCuration(source)
                guard value.analysisGeneration == source.analysisGeneration else { throw WordNoteV2ContentError.invalidState }
                let text = edit.term.trimmingCharacters(in: .whitespacesAndNewlines)
                try validateSubjectAndDefinition(text, chinese: edit.chineseMeaning, english: edit.englishDefinition, record: source)
                try validateText([edit.aiContextExplanation, edit.exampleSentence])
                value.term = text
                value.normalizedTerm = TextNormalizer.normalized(text)
                value.importance = edit.importance
                value.category = edit.category
                value.chineseMeaning = optionalText(edit.chineseMeaning)
                value.englishDefinition = optionalText(edit.englishDefinition)
                value.aiContextExplanation = optionalText(edit.aiContextExplanation)
                value.exampleSentence = optionalText(edit.exampleSentence)
                value.revision = try increment(value.revision)
                value.updatedAt = date
                sources[source.id] = source
            }
            for source in sources.values {
                source.revision = try increment(source.revision)
                source.updatedAt = date
            }
        }
    }

    public func ignoreInputRecord(_ id: UUID, expectedRevision: Int, at date: Date = Date()) throws {
        try transaction {
            try validateDate(date)
            let source = try record(id)
            try requireRevision(source.revision, expectedRevision)
            try requireEditableCuration(source)
            guard source.status != .completed else { throw WordNoteV2ContentError.invalidState }
            for value in try fetch(Candidate.self) where value.inputRecordID == id && value.status == .pending {
                value.status = .ignored
                value.revision = try increment(value.revision)
                value.updatedAt = date
            }
            source.status = .ignored
            source.queueStateRaw = "none"
            source.nextAttemptAt = nil
            source.attemptID = nil
            source.revision = try increment(source.revision)
            source.updatedAt = date
        }
    }
}
