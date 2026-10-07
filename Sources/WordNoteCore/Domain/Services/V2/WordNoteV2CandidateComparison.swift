import Foundation

extension WordNoteV2ContentService {
    /// Fetch the original IDs even if they are no longer pending. A comparison must not revive them.
    public func candidateDraftVersion(_ ids: [UUID], sourceRecordID: UUID) throws -> WordNoteDraftVersion<[WordNoteV2CandidateEdit]> {
        try WordNoteWriteGate.check(context)
        guard !context.hasChanges else { throw WordNoteV2ContentError.unsavedChanges }
        guard Set(ids).count == ids.count else { throw WordNoteV2ContentError.invalidValue }
        let source = try record(sourceRecordID)
        guard let queue = AnalysisQueueState(rawValue: source.queueStateRaw) else { throw WordNoteV2ContentError.invalidState }
        let stored = try fetch(Candidate.self)
        var candidates = try ids.map { id in
            guard let value = stored.first(where: { $0.id == id }) else { throw WordNoteV2ContentError.missingEntity }
            guard value.inputRecordID == sourceRecordID else { throw WordNoteV2ContentError.invalidState }
            return value
        }
        let selected = Set(ids)
        candidates += stored.filter { $0.inputRecordID == sourceRecordID && $0.status == .pending && !selected.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        var blocked: String?
        if candidates.contains(where: { $0.status != .pending }) {
            blocked = WordNoteV2ContentError.candidateAlreadyHandled.localizedDescription
        } else if queue == .queued || queue == .running {
            blocked = "Analysis is pending. The candidate draft cannot be rebased yet."
        } else if candidates.contains(where: { $0.analysisGeneration != source.analysisGeneration }) {
            blocked = "The candidates belong to an earlier analysis. Refresh the inbox before editing."
        }
        return WordNoteDraftVersion(candidates.map { WordNoteV2CandidateEdit($0, recordRevision: source.revision) },
                                    revision: source.revision, blockingMessage: blocked)
    }
}

extension WordNoteV2CandidateEdit {
    public static func comparisonFields(for originals: [Self]) -> [WordNoteEditField<[Self]>] {
        let list = WordNoteEditField<[Self]>("candidates", title: "Candidates", value: { values in
            values.map { Identity(id: $0.id, term: $0.term) }.sorted { $0.id.uuidString < $1.id.uuidString }
        }, display: { values in values.map { "\($0.term) [\($0.id.uuidString.prefix(8))]" }.joined(separator: "\n") })
        return [list] + originals.flatMap { original in
            let id = original.id
            let prefix = "\(original.term) / "
            return [
                field(id, "term", prefix + "Term", \.term, display: { $0 }),
                field(id, "importance", prefix + "Importance", \.importance, display: { $0.displayTitle }),
                field(id, "category", prefix + "Category", \.category, display: { $0.displayTitle }),
                field(id, "chinese", prefix + "Chinese", \.chineseMeaning, display: { $0 }),
                field(id, "english", prefix + "English", \.englishDefinition, display: { $0 }),
                field(id, "technical", prefix + "AI / CS Context", \.aiContextExplanation, display: { $0 }),
                field(id, "example", prefix + "Example", \.exampleSentence, display: { $0 }),
                WordNoteEditField("\(id).revision", title: prefix + "Revision",
                                  value: { $0.first(where: { $0.id == id })?.revision }, display: { $0.map(String.init) ?? "Unavailable" })
            ]
        }
    }

    private struct Identity: Equatable {
        let id: UUID
        let term: String
        // Names label a list change; renames are compared by the editable Term field.
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    private static func field<Field: Equatable>(
        _ id: UUID, _ name: String, _ title: String, _ keyPath: WritableKeyPath<Self, Field>, display: @escaping (Field) -> String
    ) -> WordNoteEditField<[Self]> {
        WordNoteEditField("\(id).\(name)", title: title,
                          value: { values in values.first(where: { $0.id == id }).map { $0[keyPath: keyPath] } },
                          update: { field, values in
                              guard let field, let index = values.firstIndex(where: { $0.id == id }) else { return }
                              values[index][keyPath: keyPath] = field
                          }, display: { $0.map(display) ?? "Unavailable" })
    }
}
