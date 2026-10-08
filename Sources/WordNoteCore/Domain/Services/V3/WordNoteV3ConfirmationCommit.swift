import Foundation

extension WordNoteV3ContentService {
    public func commitConfirmationPlan(
        _ plan: WordNoteV2ConfirmationPlan, choices: WordNoteV2ConfirmationChoices = .init(), at date: Date = Date()
    ) throws -> WordNoteV2ConfirmationResult {
        let resolution = try plan.resolve(choices)
        guard resolution.conflicts.isEmpty else { throw WordNoteV2ConfirmationPlanError.unresolvedConflicts }
        let token = try resolution.operationToken(plan.operationID)
        return try undoableTransaction("Confirm Candidates", scope: {
            var scope = try undoScope(candidateIDs: Set(plan.groups.flatMap { $0.candidates.map(\.id) }))
            scope.terms.formUnion(resolution.groups.filter { !$0.isNew }.map(\.targetTermID))
            return scope
        }, includingResult: { result, scope in scope.terms.formUnion(result.termIDs) }) {
            try validateDate(date)
            if try confirmationWasApplied(plan, resolution: resolution, token: token) {
                return .init(termIDs: resolution.groups.map(\.targetTermID), counts: resolution.counts, wasAlreadyApplied: true)
            }
            // Validate all dependencies and counters before the first model mutation.
            try validateConfirmationPlan(plan, resolution: resolution)
            let candidates = try fetch(Candidate.self)
            for group in resolution.groups {
                guard let primary = candidates.first(where: { $0.id == group.primaryCandidateID }) else {
                    throw WordNoteV3ContentError.missingEntity
                }
                let source = try record(primary.inputRecordID)
                let target: Term
                if group.isNew {
                    guard let type = TermType(rawValue: group.content.termTypeRaw),
                          let category = TermCategory(rawValue: group.content.categoryRaw),
                          let importance = Importance(rawValue: group.content.importanceRaw) else {
                        throw WordNoteV3ContentError.invalidState
                    }
                    target = Term(
                        id: group.targetTermID, term: group.term, termType: type,
                        chineseMeaning: group.content.chineseMeaning, englishDefinition: group.content.englishDefinition,
                        aiContextExplanation: group.content.aiContextExplanation, exampleSentence: group.content.exampleSentence,
                        contextSentence: source.rawText, courseID: source.courseID, sourceRecordID: source.id,
                        sourceType: source.sourceType, category: category, importance: importance,
                        nextReviewAt: nil, createdAt: date, updatedAt: date
                    )
                    context.insert(target)
                    context.insert(Card(termID: target.id, createdAt: date))
                } else {
                    target = try term(group.targetTermID)
                    for field in group.supplementedFields {
                        switch field {
                        case .chineseMeaning: target.chineseMeaning = group.content[field]
                        case .englishDefinition: target.englishDefinition = group.content[field]
                        case .aiContextExplanation: target.aiContextExplanation = group.content[field]
                        case .exampleSentence: target.exampleSentence = group.content[field]
                        }
                    }
                }
                var changed = !group.supplementedFields.isEmpty
                var addedSources: Set<UUID> = []
                for candidate in candidates where group.candidateIDs.contains(candidate.id) {
                    if addedSources.insert(candidate.inputRecordID).inserted {
                        let added = try addOrigin(termID: target.id, record: record(candidate.inputRecordID), at: date)
                        changed = changed || added
                    }
                    candidate.statusRaw = "saved"
                    candidate.savedTermID = target.id
                    candidate.savedLinkStateRaw = "resolved"
                    candidate.confirmationOperationID = token
                    candidate.revision = try increment(candidate.revision)
                    candidate.updatedAt = date
                }
                if !group.isNew, changed { try touch(target, at: date) }
            }
            for candidate in candidates where resolution.ignoredCandidateIDs.contains(candidate.id) {
                candidate.statusRaw = "ignored"
                candidate.revision = try increment(candidate.revision)
                candidate.updatedAt = date
            }
            for source in plan.records { try completeCuration(record(source.content.id), at: date) }
            return .init(termIDs: resolution.groups.map(\.targetTermID), counts: resolution.counts, wasAlreadyApplied: false)
        }
    }
}
