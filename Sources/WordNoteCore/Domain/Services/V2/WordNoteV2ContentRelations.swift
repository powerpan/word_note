import Foundation

public struct WordNoteV2VersionedID: Equatable, Sendable {
    public let id: UUID
    public let revision: Int
}

extension WordNoteV2ContentService {
    public func createCourse(
        courseName: String, courseCode: String? = nil, instructor: String? = nil,
        semester: String? = nil, description: String? = nil, at date: Date = Date()
    ) throws -> WordNoteV2VersionedID {
        try transaction {
            try validateDate(date)
            try validateText([courseName, courseCode, instructor, semester, description])
            guard let name = optionalText(courseName) else { throw CourseServiceError.blankCourseName }
            let value = Course(
                courseName: name, courseCode: optionalText(courseCode), instructor: optionalText(instructor),
                semester: optionalText(semester), courseDescription: optionalText(description), createdAt: date, updatedAt: date
            )
            context.insert(value)
            return WordNoteV2VersionedID(id: value.id, revision: value.revision)
        }
    }

    public func setCourseMembership(
        termID: UUID, courseID: UUID, included: Bool, expectedTermRevision: Int, at date: Date = Date()
    ) throws -> WordNoteV2VersionedID {
        try transaction {
            try validateDate(date)
            let term = try term(termID)
            try requireRevision(term.revision, expectedTermRevision)
            _ = try course(courseID)
            let changed: Bool
            if included {
                changed = try addMembership(termID: termID, courseID: courseID, at: date)
            } else {
                let links = try fetch(CourseLink.self).filter { $0.termID == termID && $0.courseID == courseID }
                guard links.count <= 1 else { throw WordNoteV2ContentError.invalidState }
                links.forEach(context.delete)
                changed = !links.isEmpty
            }
            if changed { try touch(term, at: date) }
            return WordNoteV2VersionedID(id: term.id, revision: term.revision)
        }
    }

    public func courseUsage(_ courseID: UUID) throws -> WordNoteV2CourseUsage {
        _ = try course(courseID)
        return WordNoteV2CourseUsage(
            inputRecords: try fetch(Record.self).filter { $0.courseID == courseID }.count,
            memberships: try fetch(CourseLink.self).filter { $0.courseID == courseID }.count,
            occurrences: try fetch(Occurrence.self).filter { $0.courseID == courseID }.count
        )
    }

    func addMembership(termID: UUID, courseID: UUID, at date: Date) throws -> Bool {
        _ = try course(courseID)
        let matches = try fetch(CourseLink.self).filter { $0.termID == termID && $0.courseID == courseID }
        guard matches.count <= 1 else { throw WordNoteV2ContentError.invalidState }
        guard matches.isEmpty else { return false }
        context.insert(CourseLink(termID: termID, courseID: courseID, createdAt: date))
        return true
    }

    func addOrigin(termID: UUID, record: Record, at date: Date) throws -> Bool {
        guard let surface = CaptureSurface(rawValue: record.capturedViaRaw),
              let sourceType = SourceType(rawValue: record.sourceTypeRaw) else { throw WordNoteV2ContentError.invalidState }
        let existing = try fetch(Occurrence.self).filter { $0.termID == termID && $0.captureID == record.captureID }
        guard existing.count <= 1 else { throw WordNoteV2ContentError.invalidState }
        if let source = existing.first {
            guard source.sourceRecordID == record.id, source.rawTextSnapshot == record.rawText,
                  source.note == record.note, source.courseID == record.courseID,
                  source.sourceTypeRaw == record.sourceTypeRaw, source.capturedViaRaw == record.capturedViaRaw else {
                throw WordNoteV2ContentError.invalidState
            }
        } else {
            context.insert(Occurrence(
                termID: termID, captureID: record.captureID, sourceRecordID: record.id,
                rawTextSnapshot: record.rawText, note: record.note, courseID: record.courseID,
                sourceType: sourceType, occurredAt: record.createdAt, capturedVia: surface,
                legacy: surface == .legacy, createdAt: date
            ))
        }
        let membershipAdded = try record.courseID.map { try addMembership(termID: termID, courseID: $0, at: date) } ?? false
        return existing.isEmpty || membershipAdded
    }

    func requireEditableCuration(_ record: Record) throws {
        guard let queue = AnalysisQueueState(rawValue: record.queueStateRaw), queue != .running, queue != .queued else {
            throw WordNoteV2ContentError.invalidState
        }
    }

    func validateSubjectAndDefinition(_ text: String, chinese: String?, english: String?, record: Record) throws {
        guard LookupDirectionDetector.isEnglishVocabularyTerm(text) else { throw VocabularyServiceError.englishTermRequired(text) }
        try validateText([text, chinese, english])
        guard optionalText(chinese) != nil || optionalText(english) != nil else { throw VocabularyServiceError.missingDefinition(text) }
        guard let direction = LookupDirection(rawValue: record.resolvedLookupDirectionRaw) else { throw WordNoteV2ContentError.invalidState }
        if direction == .chineseToEnglish, optionalText(chinese) == nil {
            throw VocabularyServiceError.chineseMeaningRequired(text)
        }
    }

    func completeCuration(_ record: Record, at date: Date) throws {
        let candidates = try fetch(Candidate.self).filter { $0.inputRecordID == record.id }
        if candidates.allSatisfy({ $0.statusRaw != "pending" }) { record.statusRaw = "completed" }
        record.revision = try increment(record.revision)
        record.updatedAt = date
    }
}
