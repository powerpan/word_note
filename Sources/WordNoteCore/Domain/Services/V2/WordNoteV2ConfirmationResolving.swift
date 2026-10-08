import Foundation

extension WordNoteV2ConfirmationChoices {
    public mutating func setExistingTarget(_ termID: UUID?, groupID: String, in plan: WordNoteV2ConfirmationPlan) throws {
        guard let group = plan.groups.first(where: { $0.id == groupID }), !group.existingTerms.isEmpty,
              termID == nil || group.existingTerms.contains(where: { $0.id == termID }),
              group.candidates.contains(where: { !ignoredCandidateIDs.contains($0.id) }) else {
            throw WordNoteV2ConfirmationPlanError.invalidChoice
        }
        var choice = groups[groupID] ?? .init()
        if choice.existingTermID != termID { choice.fieldSources = [:] }
        choice.existingTermID = termID
        groups[groupID] = choice
    }

    public mutating func setIgnored(_ ignored: Bool, candidateID: UUID, in plan: WordNoteV2ConfirmationPlan) throws {
        guard let group = plan.groups.first(where: { $0.candidates.contains { $0.id == candidateID } }) else {
            throw WordNoteV2ConfirmationPlanError.invalidChoice
        }
        if ignored { ignoredCandidateIDs.insert(candidateID) }
        else { ignoredCandidateIDs.remove(candidateID) }
        var choice = groups[group.id] ?? .init()
        if ignored {
            if choice.preferredCandidateID == candidateID { choice.preferredCandidateID = nil }
            choice.fieldSources = choice.fieldSources.filter { $0.value != candidateID }
        }
        if group.candidates.allSatisfy({ ignoredCandidateIDs.contains($0.id) }) { choice = .init() }
        groups[group.id] = choice
    }
}

extension WordNoteV2ConfirmationPlan {
    public func resolve(_ choices: WordNoteV2ConfirmationChoices = .init()) throws -> WordNoteV2ConfirmationResolution {
        let candidateIDs = Set(groups.flatMap { $0.candidates.map(\.id) })
        guard choices.ignoredCandidateIDs.isSubset(of: candidateIDs),
              Set(choices.groups.keys).isSubset(of: Set(groups.map(\.id))) else {
            throw WordNoteV2ConfirmationPlanError.invalidChoice
        }
        var resolved: [WordNoteV2ConfirmationResolution.Group] = []
        var conflicts: [WordNoteV2ConfirmationResolution.Conflict] = []
        for group in groups {
            let active = group.candidates.filter { !choices.ignoredCandidateIDs.contains($0.id) }
            let choice = choices.groups[group.id] ?? .init()
            guard !active.isEmpty else {
                guard choice == .init() else { throw WordNoteV2ConfirmationPlanError.invalidChoice }
                continue
            }
            if let preferred = choice.preferredCandidateID, !active.contains(where: { $0.id == preferred }) {
                throw WordNoteV2ConfirmationPlanError.invalidChoice
            }
            let primary = active.first { $0.id == choice.preferredCandidateID } ?? active[0]
            let target: Target?
            if group.existingTerms.isEmpty {
                guard choice.existingTermID == nil, choice.fieldSources.isEmpty else {
                    throw WordNoteV2ConfirmationPlanError.invalidChoice
                }
                guard choice.preferredCandidateID != nil || active.allSatisfy({ $0.values == primary.values }) else {
                    conflicts.append(.init(id: group.id, message: "Candidates differ. Choose the content to keep, or ignore a candidate."))
                    continue
                }
                target = nil
            } else {
                guard choice.preferredCandidateID == nil else { throw WordNoteV2ConfirmationPlanError.invalidChoice }
                if let selectedID = choice.existingTermID {
                    guard let selected = group.existingTerms.first(where: { $0.id == selectedID }) else {
                        throw WordNoteV2ConfirmationPlanError.invalidChoice
                    }
                    target = selected
                } else if group.existingTerms.count == 1 {
                    target = group.existingTerms[0]
                } else {
                    conflicts.append(.init(id: group.id, message: "More than one existing term matches. Choose a target."))
                    continue
                }
            }
            var content = target?.values ?? primary.values
            var supplemented: [WordNoteV2ConfirmationField] = []
            for field in WordNoteV2ConfirmationField.allCases {
                guard let sourceID = choice.fieldSources[field] else { continue }
                guard let candidate = active.first(where: { $0.id == sourceID }), let value = candidate.values[field] else {
                    throw WordNoteV2ConfirmationPlanError.invalidChoice
                }
                if content[field] != value {
                    content[field] = value
                    supplemented.append(field)
                }
            }
            let term = (target?.content.term ?? primary.content.term).trimmingCharacters(in: .whitespacesAndNewlines)
            guard TextNormalizer.normalized(term) == group.id else {
                conflicts.append(.init(id: group.id, message: "The stored headword and its lookup key disagree."))
                continue
            }
            if let issue = validationIssue(term: term, content: content, candidates: active) {
                conflicts.append(.init(id: group.id, message: issue))
                continue
            }
            resolved.append(.init(
                id: group.id, targetTermID: target?.id ?? group.proposedTermID, isNew: target == nil,
                term: term, candidateIDs: active.map(\.id), primaryCandidateID: primary.id,
                content: content, supplementedFields: supplemented
            ))
        }
        let newTerms = resolved.filter(\.isNew).count
        let savedCandidates = resolved.reduce(0) { $0 + $1.candidateIDs.count }
        return .init(
            groups: resolved, conflicts: conflicts,
            counts: .init(
                records: records.count, candidates: candidateIDs.count, newTerms: newTerms,
                linkedCandidates: savedCandidates - newTerms,
                supplementedTerms: resolved.filter { !$0.supplementedFields.isEmpty }.count,
                ignoredCandidates: choices.ignoredCandidateIDs.count,
                unresolvedCandidates: candidateIDs.count - savedCandidates - choices.ignoredCandidateIDs.count,
                conflicts: conflicts.count
            ), ignoredCandidateIDs: choices.ignoredCandidateIDs.sorted { $0.uuidString < $1.uuidString }
        )
    }

    private func validationIssue(
        term: String, content: WordNoteV2ConfirmationContent, candidates: [Candidate]
    ) -> String? {
        guard LookupDirectionDetector.isEnglishVocabularyTerm(term),
              candidates.allSatisfy({ LookupDirectionDetector.isEnglishVocabularyTerm($0.content.term) }) else {
            return "An English headword is required. Edit or ignore the candidate."
        }
        guard TermType(rawValue: content.termTypeRaw) != nil, TermCategory(rawValue: content.categoryRaw) != nil,
              Importance(rawValue: content.importanceRaw) != nil else {
            return "A candidate or target contains an unsupported value."
        }
        guard content.chineseMeaning != nil || content.englishDefinition != nil else {
            return "A definition is required. Edit the candidate or select a definition to supplement."
        }
        let sourceIDs = Set(candidates.map { $0.content.inputRecordID })
        if content.chineseMeaning == nil, records.contains(where: {
            sourceIDs.contains($0.content.id) && $0.state.resolvedLookupDirectionRaw == LookupDirection.chineseToEnglish.rawValue
        }) {
            return "Chinese-to-English lookups require a Chinese meaning."
        }
        guard ([term] + WordNoteV2ConfirmationField.allCases.compactMap { content[$0] })
            .allSatisfy({ $0.count <= WordNoteSnapshotPayload.maximumTextCharacters }) else {
            return "The content exceeds the supported size. Edit the candidate before confirming."
        }
        return nil
    }
}
