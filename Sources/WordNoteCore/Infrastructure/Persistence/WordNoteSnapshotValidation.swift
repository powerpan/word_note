import Foundation

public enum WordNoteSnapshotError: LocalizedError, Equatable {
    case invalidDocument
    case unsupportedFormat
    case unsupportedSchema
    case checksumMismatch
    case countMismatch
    case duplicateID
    case missingReference
    case invalidEnum
    case invalidValue
    case sizeLimit
    case destinationNotEmpty

    public var errorDescription: String? {
        switch self {
        case .invalidDocument: "This file is not a valid Word Note backup."
        case .unsupportedFormat: "This backup format is not supported by this version of Word Note."
        case .unsupportedSchema: "This backup uses an unsupported data schema."
        case .checksumMismatch: "The backup checksum does not match. The file may be damaged."
        case .countMismatch: "The backup's record counts do not match its contents."
        case .duplicateID: "The backup contains duplicate record identifiers."
        case .missingReference: "The backup contains a reference to a missing record."
        case .invalidEnum: "The backup contains an unsupported status or category."
        case .invalidValue: "The backup contains an invalid date or numeric value."
        case .sizeLimit: "The backup exceeds the supported file, record, or text size."
        case .destinationNotEmpty: "Restore requires a new, empty database. Existing data was not replaced."
        }
    }
}

extension WordNoteSnapshotPayload {
    public static let maximumEntityCount = 100_000
    public static let maximumTextCharacters = 1_000_000

    public func validate() throws {
        guard counts.total <= Self.maximumEntityCount else { throw WordNoteSnapshotError.sizeLimit }
        let courseIDs = try uniqueIDs(courses.map(\.id))
        let recordIDs = try uniqueIDs(inputRecords.map(\.id))
        _ = try uniqueIDs(candidates.map(\.id))
        let termIDs = try uniqueIDs(terms.map(\.id))
        _ = try uniqueIDs(reviewEvents.map(\.id))
        try validEnum(preferences.appearance, AppAppearancePreference.self)
        try validEnum(preferences.defaultSource, SourceType.self)

        for course in courses {
            try texts([course.courseName, course.courseCode, course.instructor, course.semester, course.courseDescription])
            try dates([course.createdAt, course.updatedAt])
        }
        for record in inputRecords {
            try reference(record.courseID, in: courseIDs)
            try validEnum(record.inputTypeRaw, InputType.self)
            try validEnum(record.statusRaw, InputRecordStatus.self)
            try validEnum(record.sourceTypeRaw, SourceType.self)
            try texts([record.rawText, record.normalizedText, record.sentenceMeaning, record.note, record.aiErrorSummary])
            try dates([record.createdAt, record.updatedAt, record.analyzedAt])
        }
        for candidate in candidates {
            try reference(candidate.inputRecordID, in: recordIDs)
            try validEnum(candidate.termTypeRaw, TermType.self)
            try validEnum(candidate.importanceRaw, Importance.self)
            try validEnum(candidate.categoryRaw, TermCategory.self)
            try validEnum(candidate.statusRaw, CandidateStatus.self)
            guard candidate.confidence.isFinite, (0...1).contains(candidate.confidence) else {
                throw WordNoteSnapshotError.invalidValue
            }
            try texts([
                candidate.term, candidate.normalizedTerm, candidate.reason, candidate.chineseMeaning,
                candidate.englishDefinition, candidate.aiContextExplanation, candidate.exampleSentence
            ])
            try stringList(candidate.relatedTerms)
            try dates([candidate.createdAt, candidate.updatedAt])
        }
        for term in terms {
            try reference(term.courseID, in: courseIDs)
            try reference(term.sourceRecordID, in: recordIDs)
            try validEnum(term.termTypeRaw, TermType.self)
            try validEnum(term.sourceTypeRaw, SourceType.self)
            try validEnum(term.categoryRaw, TermCategory.self)
            try validEnum(term.importanceRaw, Importance.self)
            try validEnum(term.masteryLevelRaw, MasteryLevel.self)
            let counters = [term.reviewIntervalDays, term.correctStreak, term.reviewCount, term.wrongCount, term.duplicateHitCount]
            guard counters.allSatisfy({ (0...1_000_000_000).contains($0) }) else {
                throw WordNoteSnapshotError.invalidValue
            }
            try texts([
                term.term, term.normalizedTerm, term.chineseMeaning, term.englishDefinition,
                term.aiContextExplanation, term.exampleSentence, term.contextSentence
            ])
            try stringList(term.tags)
            try dates([term.createdAt, term.updatedAt, term.lastDuplicateHitAt, term.lastReviewedAt, term.nextReviewAt])
        }
        for event in reviewEvents {
            try reference(event.termID, in: termIDs)
            try validEnum(event.modeRaw, ReviewMode.self)
            try validEnum(event.feedbackRaw, ReviewFeedback.self)
            try validEnum(event.previousMasteryLevelRaw, MasteryLevel.self)
            try validEnum(event.newMasteryLevelRaw, MasteryLevel.self)
            try dates([event.reviewedAt, event.previousNextReviewAt, event.newNextReviewAt])
        }
    }

    private func uniqueIDs(_ ids: [UUID]) throws -> Set<UUID> {
        let unique = Set(ids)
        guard unique.count == ids.count else { throw WordNoteSnapshotError.duplicateID }
        return unique
    }

    private func reference(_ id: UUID?, in identifiers: Set<UUID>) throws {
        if let id, !identifiers.contains(id) { throw WordNoteSnapshotError.missingReference }
    }

    private func validEnum<T: RawRepresentable>(_ raw: String, _ type: T.Type) throws where T.RawValue == String {
        guard T(rawValue: raw) != nil else { throw WordNoteSnapshotError.invalidEnum }
    }

    private func texts(_ values: [String?]) throws {
        guard values.allSatisfy({ ($0?.count ?? 0) <= Self.maximumTextCharacters }) else {
            throw WordNoteSnapshotError.sizeLimit
        }
    }

    private func stringList(_ values: [String]) throws {
        guard values.count <= 10_000 else { throw WordNoteSnapshotError.sizeLimit }
        try texts(values.map(Optional.some))
    }

    private func dates(_ values: [Date?]) throws {
        guard values.allSatisfy({ value in
            guard let value else { return true }
            return value.timeIntervalSince1970.isFinite && abs(value.timeIntervalSince1970) < 100_000_000_000
        }) else { throw WordNoteSnapshotError.invalidValue }
    }
}
