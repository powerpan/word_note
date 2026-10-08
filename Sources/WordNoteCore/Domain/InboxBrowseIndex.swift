import Foundation

public enum InboxStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all, pending, drafts, failed
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: "All records"
        case .pending: "Pending candidates"
        case .drafts: "Drafts"
        case .failed: "Analysis failed"
        }
    }
}

public struct InboxBrowseQuery: Equatable, Sendable {
    public var text = ""
    public var courseID: UUID?
    public var source: SourceType?
    public var status: InboxStatusFilter = .all
    public init() {}
}

public struct InboxBrowseItem: Identifiable, Sendable {
    public let record: WordNoteSnapshotPayload.InputRecord
    public let state: WordNoteSnapshotV2Payload.RecordState
    public let candidates: [WordNoteSnapshotPayload.Candidate]
    public let selections: [WordNoteV2CandidateSelection]
    private let searchEntries: [VocabularySearchMatcher.Entry]
    public var id: UUID { record.id }
    public var pendingCandidates: [WordNoteSnapshotPayload.Candidate] { candidates.filter { $0.statusRaw == "pending" } }
    public var isAnalyzing: Bool { state.queueStateRaw == "queued" || state.queueStateRaw == "running" }
    public var isFailed: Bool { state.queueStateRaw == "failed" || record.statusRaw == "failed" }
    public var isHandled: Bool { record.statusRaw == "completed" }
    public var isActive: Bool { !isAnalyzing && !isHandled && record.statusRaw != "ignored" }
    public var canConfirm: Bool {
        isActive && AnalysisQueueState(rawValue: state.queueStateRaw) != nil
            && !pendingCandidates.isEmpty && selections.count == pendingCandidates.count
    }

    @MainActor
    public init(record: WordNoteSchemaV2.InputRecordModel, candidates models: [WordNoteSchemaV2.CandidateTermModel]) {
        self.record = .init(record)
        state = .init(record)
        let matching = models.filter { $0.inputRecordID == record.id }.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
        candidates = matching.map(WordNoteSnapshotPayload.Candidate.init)
        selections = matching.filter { $0.status == .pending && $0.analysisGeneration == record.analysisGeneration }.map {
            .init(id: $0.id, revision: $0.revision, recordID: record.id, recordRevision: record.revision)
        }
        let sourceText = [record.rawText, record.note, record.sentenceMeaning].compactMap { $0 }
        searchEntries = sourceText.map { .init(term: $0, chineseMeaning: $0, englishDefinition: nil) } + candidates.map {
            .init(term: $0.term, chineseMeaning: $0.chineseMeaning, englishDefinition: $0.englishDefinition)
        }
    }

    public var preview: String {
        let ordered = pendingCandidates + candidates.filter { $0.statusRaw != "pending" }
        let values = ordered.map { state.resolvedLookupDirectionRaw == "chineseToEnglish" ? $0.term : $0.chineseMeaning }
        let text = (values + [record.sentenceMeaning]).compactMap { value -> String? in
            guard let value else { return nil }
            let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return normalized.isEmpty ? nil : normalized
        }.first
        return text.map { String($0.prefix(18)) } ?? statusTitle
    }

    public var statusTitle: String {
        if isFailed { return "Analysis failed" }
        if state.queueStateRaw == "cancelled" { return "Analysis cancelled" }
        return InputRecordStatus(rawValue: record.statusRaw)?.displayTitle ?? "Unavailable"
    }

    func matches(_ query: InboxBrowseQuery, search: VocabularySearchMatcher.Query) -> Bool {
        (query.courseID.map { record.courseID == $0 } ?? true)
            && (query.source.map { record.sourceTypeRaw == $0.rawValue } ?? true)
            && searchEntries.contains { $0.matches(search) }
    }
}

public struct InboxBrowseResult: Sendable {
    public let active: [InboxBrowseItem]
    public let handled: [InboxBrowseItem]
    public var confirmableIDs: Set<UUID> { Set(active.filter(\.canConfirm).map(\.id)) }

    public func selectedCounts(_ ids: Set<UUID>) -> (records: Int, candidates: Int) {
        let selected = active.filter { $0.canConfirm && ids.contains($0.id) }
        return (selected.count, selected.reduce(0) { $0 + $1.selections.count })
    }
}

public struct InboxBrowseIndex: Sendable {
    public let items: [InboxBrowseItem]
    public init(items: [InboxBrowseItem] = []) {
        self.items = items.sorted {
            $0.record.createdAt == $1.record.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.record.createdAt > $1.record.createdAt
        }
    }

    public func matching(_ query: InboxBrowseQuery) -> InboxBrowseResult {
        let search = VocabularySearchMatcher.Query(query.text)
        let filtered = items.filter { $0.matches(query, search: search) }
        return .init(active: filtered.filter { item in
            guard item.isActive else { return false }
            switch query.status {
            case .all: return true
            case .pending: return !item.pendingCandidates.isEmpty
            case .drafts: return item.record.statusRaw == "draft" && item.pendingCandidates.isEmpty && !item.isFailed
            case .failed: return item.isFailed
            }
        }, handled: query.status == .all ? filtered.filter { $0.isHandled && !$0.isAnalyzing } : [])
    }
}
