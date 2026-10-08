import Foundation

extension WordNoteV3ContentService {
    func confirmationWasApplied(
        _ plan: WordNoteV2ConfirmationPlan, resolution: WordNoteV2ConfirmationResolution, token: UUID
    ) throws -> Bool {
        let candidates = try fetch(Candidate.self)
        let selected = plan.groups.flatMap(\.candidates)
        for expected in selected {
            guard let current = candidates.first(where: { $0.id == expected.id }) else { return false }
            var content = WordNoteSnapshotPayload.Candidate(current)
            var state = WordNoteSnapshotV2Payload.CandidateState(current)
            guard current.revision == (try increment(expected.state.revision)) else { return false }
            if let group = resolution.groups.first(where: { $0.candidateIDs.contains(expected.id) }) {
                guard current.statusRaw == "saved", current.confirmationOperationID == token else { return false }
                guard current.savedLinkStateRaw == "resolved", current.savedTermID == group.targetTermID else {
                    throw WordNoteV3ContentError.savedTargetDeleted
                }
                _ = try term(group.targetTermID)
            } else {
                // Ignored candidates cannot store confirmation tokens in the frozen V2 schema.
                // Accept only an exact terminal-state match; this is convergence, not an ownership receipt.
                guard resolution.ignoredCandidateIDs.contains(expected.id), current.statusRaw == "ignored",
                      current.savedLinkStateRaw == "none", current.savedTermID == nil,
                      current.confirmationOperationID == nil else { return false }
            }
            content.statusRaw = expected.content.statusRaw
            content.updatedAt = expected.content.updatedAt
            state.revision = expected.state.revision
            state.savedTermID = expected.state.savedTermID
            state.savedLinkStateRaw = expected.state.savedLinkStateRaw
            state.confirmationOperationID = expected.state.confirmationOperationID
            guard content == expected.content, state == expected.state else { return false }
        }
        for expected in plan.records {
            guard let current = try fetch(Record.self).first(where: { $0.id == expected.content.id }),
                  current.revision == (try increment(expected.state.revision)) else { return false }
            let hasPending = candidates.contains { $0.inputRecordID == current.id && $0.statusRaw == "pending" }
            guard current.statusRaw == (hasPending ? expected.content.statusRaw : "completed") else { return false }
            var content = WordNoteSnapshotPayload.InputRecord(current)
            var state = WordNoteSnapshotV2Payload.RecordState(current)
            content.statusRaw = expected.content.statusRaw
            content.updatedAt = expected.content.updatedAt
            state.revision = expected.state.revision
            guard content == expected.content, state == expected.state else { return false }
        }
        return true
    }
}
