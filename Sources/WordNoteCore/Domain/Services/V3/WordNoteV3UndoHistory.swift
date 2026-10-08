import Foundation
import Observation
import SwiftData

public enum WordNoteV3UndoError: LocalizedError, Equatable {
    case unavailable
    case differentStore
    case changedSinceSave
    case newerChange

    public var errorDescription: String? {
        switch self {
        case .unavailable: "There is no saved change to undo in this app session."
        case .differentStore: "This saved change belongs to a different database."
        case .changedSinceSave: "This change cannot be undone because its content or references changed afterwards. No data was changed."
        case .newerChange: "Another change was saved. Review the current Undo action and try again."
        }
    }
}

/// One receipt per running V3 container, shared by its windows; never persisted or used as a backup.
@MainActor
@Observable
public final class WordNoteV3UndoHistory {
    @ObservationIgnored private let container: ModelContainer
    private(set) var receipt: WordNoteV3UndoReceipt?
    public var title: String? { receipt?.title }
    public var operationID: UUID? { receipt?.id }
    public var canUndo: Bool { receipt != nil }

    public init(container: ModelContainer) throws {
        guard container.schema.version == WordNoteSchemaV3.versionIdentifier else { throw WordNoteV3ContentError.wrongSchema }
        self.container = container
    }

    func checkContainer(_ container: ModelContainer) throws {
        guard self.container === container else { throw WordNoteV3UndoError.differentStore }
    }

    func record(_ receipt: WordNoteV3UndoReceipt) { self.receipt = receipt }
    func clear() { receipt = nil }

    public func undo(expectedOperationID: UUID? = nil, at date: Date = Date()) throws {
        try WordNoteV3ContentService(container: container, undoHistory: self).undoLastChange(expectedOperationID: expectedOperationID, at: date)
    }
}

struct WordNoteV3UndoScope: Equatable, Sendable {
    var courses = Set<UUID>()
    var records = Set<UUID>()
    var candidates = Set<UUID>()
    var terms = Set<UUID>()
    var createdCourses = Set<UUID>()
}

struct WordNoteV3UndoSlice: Equatable, Sendable {
    // This is a partial set of DTOs, not a valid full-store snapshot.
    let values: WordNoteSnapshotV2Payload
    let candidateReferences: Set<CandidateReference>
    let sourceTerms: Set<UUID>
    let sourceOccurrences: Set<UUID>
    let createdCourseReferences: Set<Reference>
    let review: ReviewState

    struct ReviewState: Equatable, Sendable {
        let histories: [WordNoteSnapshotV3Payload.TermHistory]
        let cards: [WordNoteSnapshotV3Payload.Card]
        let events: [WordNoteSnapshotV3Payload.EventState]
        let sessions: [WordNoteSnapshotV3Payload.Session]
        let items: [WordNoteSnapshotV3Payload.SessionItem]
    }

    struct CandidateReference: Hashable, Sendable {
        let id: UUID
        let revision: Int
        let recordID: UUID
        let termID: UUID?
        let linkState: String
    }

    struct Reference: Hashable, Sendable {
        let kind: String
        let id: UUID
    }
}

struct WordNoteV3UndoReceipt: Equatable, Sendable {
    let id = UUID()
    let title: String
    let scope: WordNoteV3UndoScope
    let before: WordNoteV3UndoSlice
    let after: WordNoteV3UndoSlice
}

extension WordNoteV3ContentService {
    func undoableTransaction<Result>(
        _ title: String, scope makeScope: () throws -> WordNoteV3UndoScope,
        includingResult: (Result, inout WordNoteV3UndoScope) -> Void = { _, _ in },
        _ body: () throws -> Result
    ) throws -> Result {
        guard let undoHistory else { return try transaction(body) }
        let outcome: (Result, WordNoteV3UndoReceipt?) = try transaction {
            var scope = try makeScope()
            let before = try undoSlice(scope)
            let result = try body()
            guard context.hasChanges else { return (result, nil) }
            includingResult(result, &scope)
            let after = try undoSlice(scope)
            return (result, WordNoteV3UndoReceipt(title: title, scope: scope, before: before, after: after))
        }
        // A failed save must not replace the previous successful receipt.
        if let receipt = outcome.1 { undoHistory.record(receipt) }
        return outcome.0
    }

    func undoScope(candidateIDs: Set<UUID>) throws -> WordNoteV3UndoScope {
        let ids = Array(candidateIDs)
        let candidates = try undoModels(Candidate.self, matching: \.id, in: ids)
        return WordNoteV3UndoScope(records: Set(candidates.map(\.inputRecordID)), candidates: candidateIDs,
                                   terms: Set(candidates.compactMap(\.savedTermID)))
    }

    public func undoLastChange(expectedOperationID: UUID? = nil, at date: Date = Date()) throws {
        guard let undoHistory, let receipt = undoHistory.receipt else { throw WordNoteV3UndoError.unavailable }
        if let expectedOperationID, expectedOperationID != receipt.id { throw WordNoteV3UndoError.newerChange }
        do {
            try transaction {
                try validateDate(date)
                guard try undoSlice(receipt.scope) == receipt.after else { throw WordNoteV3UndoError.changedSinceSave }
                try validateUndoReferences(receipt)
                try applyUndo(receipt, at: date)
            }
            undoHistory.clear()
        } catch {
            if error as? WordNoteV3UndoError == .changedSinceSave { undoHistory.clear() }
            throw error
        }
    }
}
