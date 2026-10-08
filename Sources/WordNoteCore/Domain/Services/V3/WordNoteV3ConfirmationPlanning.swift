import Foundation

extension WordNoteV3ContentService {
    /// Retains the exact candidate selection. Handled or deleted candidates must be reselected in Inbox.
    public func refreshConfirmationPlan(_ plan: WordNoteV2ConfirmationPlan) throws -> WordNoteV2ConfirmationPlan {
        let candidates = try fetch(Candidate.self)
        let selections = try plan.groups.flatMap(\.candidates).map { expected in
            guard let current = candidates.first(where: { $0.id == expected.id }),
                  current.inputRecordID == expected.content.inputRecordID else { throw WordNoteV3ContentError.missingEntity }
            return WordNoteV2CandidateSelection(
                id: current.id, revision: current.revision, recordID: current.inputRecordID,
                recordRevision: try record(current.inputRecordID).revision
            )
        }
        return try makeConfirmationPlan(selections)
    }

    public func makeConfirmationPlan(
        _ selections: [WordNoteV2CandidateSelection]
    ) throws -> WordNoteV2ConfirmationPlan {
        try WordNoteWriteGate.check(context)
        guard !context.hasChanges else { throw WordNoteV3ContentError.unsavedChanges }
        guard !selections.isEmpty else { throw WordNoteV2ConfirmationPlanError.emptySelection }
        guard Set(selections.map(\.id)).count == selections.count else { throw WordNoteV3ContentError.invalidState }
        let allCandidates = try fetch(Candidate.self)
        let allRecords = try fetch(Record.self)
        var selected: [WordNoteV2ConfirmationPlan.Candidate] = []
        var sources: [UUID: WordNoteV2ConfirmationPlan.Record] = [:]
        for selection in selections {
            guard let candidate = allCandidates.first(where: { $0.id == selection.id }),
                  candidate.inputRecordID == selection.recordID else { throw WordNoteV3ContentError.missingEntity }
            try requireRevision(candidate.revision, selection.revision)
            guard candidate.statusRaw == "pending", candidate.savedLinkStateRaw == "none",
                  candidate.savedTermID == nil, candidate.confirmationOperationID == nil else {
                throw WordNoteV3ContentError.candidateAlreadyHandled
            }
            guard let source = allRecords.first(where: { $0.id == selection.recordID }) else {
                throw WordNoteV3ContentError.missingEntity
            }
            try requireRevision(source.revision, selection.recordRevision)
            try requireEditableCuration(source)
            guard candidate.analysisGeneration == source.analysisGeneration,
                  candidate.normalizedTerm == TextNormalizer.normalized(candidate.term) else {
                throw WordNoteV3ContentError.invalidState
            }
            selected.append(.init(content: .init(candidate), state: .init(candidate)))
            sources[source.id] = .init(content: .init(source), state: .init(source))
        }
        let grouped = Dictionary(grouping: selected, by: { $0.content.normalizedTerm })
        let targets = try confirmationTargets(normalizedNames: Set(grouped.keys))
        let courses = try Set(sources.values.compactMap { $0.content.courseID }).map { id in
            let course = try course(id)
            return WordNoteV2ConfirmationPlan.Course(content: .init(course), revision: course.revision)
        }.sorted { $0.content.id.uuidString < $1.content.id.uuidString }
        return .init(
            operationID: UUID(), groups: grouped.keys.sorted().map { name in
                .init(id: name, candidates: grouped[name, default: []].sorted { $0.id.uuidString < $1.id.uuidString },
                      existingTerms: targets.filter { $0.content.normalizedTerm == name }, proposedTermID: UUID())
            }, records: sources.values.sorted { $0.content.id.uuidString < $1.content.id.uuidString }, courses: courses
        )
    }

    func validateConfirmationPlan(
        _ plan: WordNoteV2ConfirmationPlan, resolution: WordNoteV2ConfirmationResolution
    ) throws {
        let candidates = try fetch(Candidate.self)
        for expected in plan.groups.flatMap(\.candidates) {
            guard let current = candidates.first(where: { $0.id == expected.id }),
                  WordNoteSnapshotPayload.Candidate(current) == expected.content,
                  WordNoteSnapshotV2Payload.CandidateState(current) == expected.state else {
                throw WordNoteV2ConfirmationPlanError.stalePlan
            }
            _ = try increment(current.revision)
        }
        let records = try fetch(Record.self)
        for expected in plan.records {
            guard let current = records.first(where: { $0.id == expected.content.id }),
                  WordNoteSnapshotPayload.InputRecord(current) == expected.content,
                  WordNoteSnapshotV2Payload.RecordState(current) == expected.state else {
                throw WordNoteV2ConfirmationPlanError.stalePlan
            }
            try requireEditableCuration(current)
            _ = try increment(current.revision)
        }
        let courses = try fetch(Course.self)
        for expected in plan.courses {
            guard let current = courses.first(where: { $0.id == expected.content.id }),
                  WordNoteSnapshotPayload.Course(current) == expected.content, current.revision == expected.revision else {
                throw WordNoteV2ConfirmationPlanError.stalePlan
            }
        }
        let activeNames = Set(resolution.groups.map(\.id))
        let targets = try confirmationTargets(normalizedNames: activeNames)
        for group in plan.groups where activeNames.contains(group.id) {
            guard targets.filter({ $0.content.normalizedTerm == group.id }) == group.existingTerms else {
                throw WordNoteV2ConfirmationPlanError.stalePlan
            }
        }
        let allTerms = try fetch(Term.self)
        let selectedByID = Dictionary(uniqueKeysWithValues: plan.groups.flatMap(\.candidates).map { ($0.id, $0) })
        let sourcesByID = Dictionary(uniqueKeysWithValues: plan.records.map { ($0.content.id, $0) })
        for group in resolution.groups {
            if group.isNew, allTerms.contains(where: { $0.id == group.targetTermID }) {
                throw WordNoteV2ConfirmationPlanError.stalePlan
            }
            let target = targets.first { $0.id == group.targetTermID }
            let sourceIDs = Set(group.candidateIDs.compactMap { selectedByID[$0]?.content.inputRecordID })
            let sources = sourceIDs.compactMap { sourcesByID[$0] }
            try validateConfirmationOrigins(target: target, sources: sources)
            for source in sources {
                try validateSubjectAndDefinition(
                    group.term, chinese: group.content.chineseMeaning, english: group.content.englishDefinition,
                    record: record(source.content.id)
                )
                try validateText([source.content.rawText, source.content.note])
            }
            if let target, !group.supplementedFields.isEmpty || sources.contains(where: { source in
                !target.occurrences.contains { $0.captureID == source.state.captureID }
                    || (source.content.courseID.map { id in !target.courseLinks.contains { $0.courseID == id } } ?? false)
            }) {
                _ = try increment(target.state.revision)
            }
        }
    }

    private func confirmationTargets(normalizedNames: Set<String>) throws -> [WordNoteV2ConfirmationPlan.Target] {
        let occurrences = try fetch(Occurrence.self).map(WordNoteSnapshotV2Payload.Occurrence.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let links = try fetch(CourseLink.self).map(WordNoteSnapshotV2Payload.CourseLink.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return try fetch(Term.self).filter { normalizedNames.contains($0.normalizedTerm) }.map { term in
            .init(content: .init(term), state: .init(term), occurrences: occurrences.filter { $0.termID == term.id },
                  courseLinks: links.filter { $0.termID == term.id })
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func validateConfirmationOrigins(
        target: WordNoteV2ConfirmationPlan.Target?, sources: [WordNoteV2ConfirmationPlan.Record]
    ) throws {
        guard Set(sources.map { $0.state.captureID }).count == sources.count else { throw WordNoteV3ContentError.invalidState }
        for source in sources {
            guard CaptureSurface(rawValue: source.state.capturedViaRaw) != nil,
                  SourceType(rawValue: source.content.sourceTypeRaw) != nil else { throw WordNoteV3ContentError.invalidState }
            let origins = target?.occurrences.filter { $0.captureID == source.state.captureID } ?? []
            guard origins.count <= 1 else { throw WordNoteV3ContentError.invalidState }
            if let origin = origins.first {
                guard origin.sourceRecordID == source.content.id, origin.rawTextSnapshot == source.content.rawText,
                      origin.note == source.content.note, origin.courseID == source.content.courseID,
                      origin.sourceTypeRaw == source.content.sourceTypeRaw, origin.capturedViaRaw == source.state.capturedViaRaw else {
                    throw WordNoteV3ContentError.invalidState
                }
            }
            if let courseID = source.content.courseID,
               (target?.courseLinks.filter { $0.courseID == courseID }.count ?? 0) > 1 {
                throw WordNoteV3ContentError.invalidState
            }
        }
    }
}
