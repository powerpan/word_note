import Foundation
import SwiftData

public enum WordNoteV2ContentError: LocalizedError, Equatable {
    case wrongSchema
    case unsavedChanges
    case missingEntity
    case revisionConflict(expected: Int, actual: Int)
    case captureConflict
    case ambiguousExactMatch
    case invalidState
    case invalidValue
    case counterLimit
    case candidateAlreadyHandled
    case savedTargetDeleted
    case courseInUse(WordNoteV2CourseUsage)

    public var errorDescription: String? {
        switch self {
        case .wrongSchema: "This operation requires a V2 database."
        case .unsavedChanges: "Save or discard the current edit before changing other content."
        case .missingEntity: "The selected item no longer exists. Refresh and try again."
        case .revisionConflict: "This item changed after it was selected. Refresh before saving."
        case .captureConflict: "This submission identifier was already used for different content."
        case .ambiguousExactMatch: "Multiple vocabulary entries match exactly. Resolve the duplicate entries before looking up this term."
        case .invalidState: "The stored content has conflicting states or references. No changes were saved."
        case .invalidValue: "The input contains an unsupported value or exceeds the supported size."
        case .counterLimit: "A stored counter has reached its supported limit. No changes were saved."
        case .candidateAlreadyHandled: "This candidate has already been handled. Refresh the inbox."
        case .savedTargetDeleted: "The term saved by this operation was deleted. It was not recreated."
        case .courseInUse: "This course is still referenced by input records, vocabulary, or sources."
        }
    }
}

public struct WordNoteV2CourseUsage: Equatable, Sendable {
    public let inputRecords: Int
    public let memberships: Int
    public let occurrences: Int
    public var isInUse: Bool { inputRecords > 0 || memberships > 0 || occurrences > 0 }
}

/// The V2 single-writer boundary. UI edits must stay in value drafts, not this context.
@MainActor
public final class WordNoteV2ContentService {
    typealias Course = WordNoteSchemaV2.CourseModel
    typealias Record = WordNoteSchemaV2.InputRecordModel
    typealias Candidate = WordNoteSchemaV2.CandidateTermModel
    typealias Term = WordNoteSchemaV2.TermModel
    typealias ReviewEvent = WordNoteSchemaV2.ReviewEventModel
    typealias Occurrence = WordNoteSchemaV2.TermOccurrenceModel
    typealias CourseLink = WordNoteSchemaV2.TermCourseLinkModel
    typealias LookupEvent = WordNoteSchemaV2.LookupEventModel

    let context: ModelContext
    private let container: ModelContainer
    private let save: @MainActor (ModelContext) throws -> Void

    public convenience init(container: ModelContainer) throws {
        try self.init(container: container, save: { try $0.save() })
    }

    init(container: ModelContainer, save: @escaping @MainActor (ModelContext) throws -> Void) throws {
        guard container.schema.version == WordNoteSchemaV2.versionIdentifier else { throw WordNoteV2ContentError.wrongSchema }
        self.container = container
        context = container.mainContext
        context.autosaveEnabled = false
        self.save = save
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try WordNoteWriteGate.check(context)
        guard !context.hasChanges else { throw WordNoteV2ContentError.unsavedChanges }
        do {
            let result = try body()
            if context.hasChanges { try save(context) }
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    func fetch<T: PersistentModel>(_ type: T.Type) throws -> [T] {
        try context.fetch(FetchDescriptor<T>())
    }

    func term(_ id: UUID) throws -> Term {
        guard let value = try fetch(Term.self).first(where: { $0.id == id }) else { throw WordNoteV2ContentError.missingEntity }
        return value
    }

    func record(_ id: UUID) throws -> Record {
        guard let value = try fetch(Record.self).first(where: { $0.id == id }) else { throw WordNoteV2ContentError.missingEntity }
        return value
    }

    func course(_ id: UUID) throws -> Course {
        guard let value = try fetch(Course.self).first(where: { $0.id == id }) else { throw WordNoteV2ContentError.missingEntity }
        return value
    }

    func requireRevision(_ actual: Int, _ expected: Int) throws {
        guard actual == expected else { throw WordNoteV2ContentError.revisionConflict(expected: expected, actual: actual) }
    }

    func increment(_ value: Int) throws -> Int {
        guard (0..<1_000_000_000).contains(value) else { throw WordNoteV2ContentError.counterLimit }
        return value + 1
    }

    func validateDate(_ date: Date) throws {
        guard date.timeIntervalSince1970.isFinite, abs(date.timeIntervalSince1970) < 100_000_000_000 else {
            throw WordNoteV2ContentError.invalidValue
        }
    }

    func validateText(_ values: [String?]) throws {
        guard values.allSatisfy({ ($0?.count ?? 0) <= WordNoteSnapshotPayload.maximumTextCharacters }) else {
            throw WordNoteV2ContentError.invalidValue
        }
    }

    func optionalText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
    }

    func touch(_ term: Term, at date: Date) throws {
        term.revision = try increment(term.revision)
        term.updatedAt = date
    }
}
