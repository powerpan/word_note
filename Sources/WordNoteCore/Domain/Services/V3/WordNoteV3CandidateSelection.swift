import Foundation

extension WordNoteV3ContentService {
    /// Compatibility API for explicitly new-only callers. Inbox uses the read-only confirmation plan.
    public func confirmNewCandidates(
        _ selections: [WordNoteV2CandidateSelection], at date: Date = Date()
    ) throws -> [WordNoteV2VersionedID] {
        try undoableTransaction("Confirm Candidates", scope: { try undoScope(candidateIDs: Set(selections.map(\.id))) },
                               includingResult: { results, scope in scope.terms.formUnion(results.map(\.id)) }) {
            try validateDate(date)
            try validateSelections(selections)
            return try selections.map { selection in
                try confirmCandidateInTransaction(
                    selection.id, expectedRevision: selection.revision,
                    expectedRecordRevision: record(selection.recordID).revision,
                    operationID: UUID(), target: .createNew, at: date
                )
            }
        }
    }

    public func ignoreCandidates(_ selections: [WordNoteV2CandidateSelection], at date: Date = Date()) throws {
        try undoableTransaction("Ignore Candidates", scope: { try undoScope(candidateIDs: Set(selections.map(\.id))) }) {
            try validateDate(date)
            try validateSelections(selections)
            let selectedIDs = Set(selections.map(\.id))
            for candidate in try fetch(Candidate.self) where selectedIDs.contains(candidate.id) {
                candidate.status = .ignored
                candidate.revision = try increment(candidate.revision)
                candidate.updatedAt = date
            }
            for id in Set(selections.map(\.recordID)) { try completeCuration(record(id), at: date) }
        }
    }

    private func validateSelections(_ selections: [WordNoteV2CandidateSelection]) throws {
        guard Set(selections.map(\.id)).count == selections.count else { throw WordNoteV3ContentError.invalidState }
        let candidates = try fetch(Candidate.self)
        for selection in selections {
            guard let candidate = candidates.first(where: { $0.id == selection.id }),
                  candidate.inputRecordID == selection.recordID else { throw WordNoteV3ContentError.missingEntity }
            try requireRevision(candidate.revision, selection.revision)
            guard candidate.status == .pending else { throw WordNoteV3ContentError.candidateAlreadyHandled }
            let source = try record(selection.recordID)
            try requireRevision(source.revision, selection.recordRevision)
            try requireEditableCuration(source)
            guard candidate.analysisGeneration == source.analysisGeneration else { throw WordNoteV3ContentError.invalidState }
        }
    }
}
