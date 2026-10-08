import Foundation

extension WordNoteV3ContentService {
    /// Fetch the original IDs even if they are no longer pending. A comparison must not revive them.
    public func candidateDraftVersion(_ ids: [UUID], sourceRecordID: UUID) throws -> WordNoteDraftVersion<[WordNoteV2CandidateEdit]> {
        try WordNoteWriteGate.check(context)
        guard !context.hasChanges else { throw WordNoteV3ContentError.unsavedChanges }
        guard Set(ids).count == ids.count else { throw WordNoteV3ContentError.invalidValue }
        let source = try record(sourceRecordID)
        guard let queue = AnalysisQueueState(rawValue: source.queueStateRaw) else { throw WordNoteV3ContentError.invalidState }
        let stored = try fetch(Candidate.self)
        var candidates = try ids.map { id in
            guard let value = stored.first(where: { $0.id == id }) else { throw WordNoteV3ContentError.missingEntity }
            guard value.inputRecordID == sourceRecordID else { throw WordNoteV3ContentError.invalidState }
            return value
        }
        let selected = Set(ids)
        candidates += stored.filter { $0.inputRecordID == sourceRecordID && $0.status == .pending && !selected.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        var blocked: String?
        if candidates.contains(where: { $0.status != .pending }) {
            blocked = WordNoteV3ContentError.candidateAlreadyHandled.localizedDescription
        } else if queue == .queued || queue == .running {
            blocked = "Analysis is pending. The candidate draft cannot be rebased yet."
        } else if candidates.contains(where: { $0.analysisGeneration != source.analysisGeneration }) {
            blocked = "The candidates belong to an earlier analysis. Refresh the inbox before editing."
        }
        return WordNoteDraftVersion(candidates.map { WordNoteV2CandidateEdit($0, recordRevision: source.revision) },
                                    revision: source.revision, blockingMessage: blocked)
    }
}
