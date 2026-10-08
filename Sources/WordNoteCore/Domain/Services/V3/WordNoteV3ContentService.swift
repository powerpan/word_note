import Foundation
import SwiftData

public struct WordNoteV3CourseUsage: Equatable, Sendable {
    public let inputRecords: Int
    public let memberships: Int
    public let occurrences: Int
    public var isInUse: Bool { inputRecords > 0 || memberships > 0 || occurrences > 0 }
}

public enum WordNoteV3ContentError: LocalizedError, Equatable {
    case wrongSchema, unsavedChanges, missingEntity, invalidValue, counterLimit
    case captureConflict, ambiguousExactMatch, invalidState
    case revisionConflict(expected: Int, actual: Int)
    case courseInUse(WordNoteV3CourseUsage)

    public var errorDescription: String? {
        switch self {
        case .wrongSchema: "This operation requires a V3 database."
        case .unsavedChanges: "Save or discard the current edit before changing other content."
        case .missingEntity: "The selected item no longer exists. Refresh and try again."
        case .invalidValue: "The operation contains an unsupported value. No changes were saved."
        case .counterLimit: "A stored counter has reached its supported limit. No changes were saved."
        case .captureConflict: "This submission identifier was already used for different content."
        case .ambiguousExactMatch: "Multiple vocabulary entries match exactly. Resolve the duplicate entries before looking up this term."
        case .invalidState: "The stored content has conflicting states or references. No changes were saved."
        case .revisionConflict: "This item changed after it was selected. Refresh before saving."
        case .courseInUse: "This course is still referenced by input records, vocabulary, or sources."
        }
    }
}

/// V3 mutations use one MainActor context. Never attach a V1/V2 writer to this container.
@MainActor
public final class WordNoteV3ContentService {
    typealias Course = WordNoteSchemaV3.CourseModel
    typealias Record = WordNoteSchemaV3.InputRecordModel
    typealias Candidate = WordNoteSchemaV3.CandidateTermModel
    typealias Term = WordNoteSchemaV3.TermModel
    typealias ReviewEvent = WordNoteSchemaV3.ReviewEventModel
    typealias Occurrence = WordNoteSchemaV3.TermOccurrenceModel
    typealias CourseLink = WordNoteSchemaV3.TermCourseLinkModel
    typealias LookupEvent = WordNoteSchemaV3.LookupEventModel
    typealias Card = WordNoteSchemaV3.ReviewCardModel
    typealias Session = WordNoteSchemaV3.ReviewSessionModel
    typealias SessionItem = WordNoteSchemaV3.ReviewSessionItemModel

    let context: ModelContext
    private let container: ModelContainer
    private let beforeSave: @MainActor (ModelContext) throws -> Void

    public convenience init(container: ModelContainer) throws {
        try self.init(container: container, beforeSave: { _ in })
    }

    init(container: ModelContainer, beforeSave: @escaping @MainActor (ModelContext) throws -> Void) throws {
        guard container.schema.version == WordNoteSchemaV3.versionIdentifier else { throw WordNoteV3ContentError.wrongSchema }
        self.container = container
        context = container.mainContext
        context.autosaveEnabled = false
        self.beforeSave = beforeSave
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try WordNoteWriteGate.check(context)
        guard !context.hasChanges else { throw WordNoteV3ContentError.unsavedChanges }
        // Content mutations must not double as an unreviewed repair of preexisting damage.
        _ = try WordNoteSnapshotV3Payload.capture(from: context)
        do {
            let result = try body()
            if context.hasChanges {
                _ = try WordNoteSnapshotV3Payload.capture(from: context)
                try beforeSave(context)
                try context.save()
            }
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    func fetch<T: PersistentModel>(_ type: T.Type) throws -> [T] { try context.fetch(FetchDescriptor<T>()) }

    func term(_ id: UUID) throws -> Term {
        guard let value = try fetch(Term.self).first(where: { $0.id == id }) else { throw WordNoteV3ContentError.missingEntity }
        return value
    }

    func course(_ id: UUID) throws -> Course {
        guard let value = try fetch(Course.self).first(where: { $0.id == id }) else { throw WordNoteV3ContentError.missingEntity }
        return value
    }

    func requireRevision(_ actual: Int, _ expected: Int) throws {
        guard actual == expected else { throw WordNoteV3ContentError.revisionConflict(expected: expected, actual: actual) }
    }

    func increment(_ value: Int) throws -> Int {
        guard (0..<1_000_000_000).contains(value) else { throw WordNoteV3ContentError.counterLimit }
        return value + 1
    }

    func validateDate(_ date: Date) throws {
        guard date.timeIntervalSince1970.isFinite, abs(date.timeIntervalSince1970) < 100_000_000_000 else {
            throw WordNoteV3ContentError.invalidValue
        }
    }

    func touch(_ term: Term, at date: Date) throws {
        term.revision = try increment(term.revision)
        term.updatedAt = date
    }

    func validateText(_ values: [String?]) throws {
        guard values.allSatisfy({ ($0?.count ?? 0) <= WordNoteSnapshotPayload.maximumTextCharacters }) else {
            throw WordNoteV3ContentError.invalidValue
        }
    }

    func optionalText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
    }

    @discardableResult
    func addMembership(termID: UUID, courseID: UUID, at date: Date) throws -> Bool {
        guard try !fetch(CourseLink.self).contains(where: { $0.termID == termID && $0.courseID == courseID }) else { return false }
        context.insert(CourseLink(termID: termID, courseID: courseID, createdAt: date))
        return true
    }
}
