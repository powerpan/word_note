import Foundation

public struct LearningOverviewSnapshot: Sendable {
    public let statistics: ReviewStatisticsSnapshot
    public let courses: [WordNoteSnapshotPayload.Course]
    public let terms: [WordNoteSnapshotPayload.Term]
    public let cards: [ReviewCardLearningItem]
    public let weakTermIDs: Set<UUID>
    public let recentOccurrences: [WordNoteSnapshotV2Payload.Occurrence]
    public let pendingRecords: [InboxBrowseItem]
    public let resumableSession: WordNoteV3ReviewSessionSnapshot?
}

public struct LearningOverviewBuilder: Sendable {
    private let payload: WordNoteSnapshotV3Payload
    private let statisticsBuilder: ReviewStatisticsBuilder
    public init(payload: WordNoteSnapshotV3Payload) throws {
        statisticsBuilder = try ReviewStatisticsBuilder(payload: payload)
        self.payload = payload
    }

    public func overview(courseID: UUID? = nil, mode: ReviewMode, studyTimeZoneID: String,
                         at date: Date = Date()) throws -> LearningOverviewSnapshot {
        let classified = try statisticsBuilder.classifiedOverview(courseID: courseID, mode: mode,
            studyTimeZoneID: studyTimeZoneID, at: date)
        let cards = classified.cards.sorted {
                let order = $0.term.term.localizedStandardCompare($1.term.term)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
        let ids = Set(payload.content.courseLinks.filter { $0.courseID == courseID }.map(\.termID))
        let terms = payload.content.content.terms.filter { courseID == nil || ids.contains($0.id) }.sorted {
            let order = $0.term.localizedStandardCompare($1.term)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        let states = Dictionary(uniqueKeysWithValues: payload.content.recordStates.map { ($0.id, $0) })
        let candidateStates = Dictionary(uniqueKeysWithValues: payload.content.candidateStates.map { ($0.id, $0) })
        let candidates = Dictionary(grouping: payload.content.content.candidates, by: \.inputRecordID)
        let records = try payload.content.content.inputRecords.filter { courseID == nil || $0.courseID == courseID }.map { record in
            guard let state = states[record.id] else { throw WordNoteSnapshotError.missingReference }
            return InboxBrowseItem(record: record, state: state, candidates: candidates[record.id, default: []], candidateStates: candidateStates)
        }
        let occurrences = payload.content.occurrences.filter {
            $0.occurredAt <= date && (courseID == nil || $0.courseID == courseID)
        }.sorted { ($0.occurredAt, $0.id.uuidString) > ($1.occurredAt, $1.id.uuidString) }
        let resumable = payload.sessions.first { $0.status.isResumable }.map { session in
            WordNoteV3ReviewSessionSnapshot(session: session, items: payload.sessionItems.filter { $0.sessionID == session.id }
                .sorted { $0.position < $1.position })
        }
        return .init(statistics: classified.statistics, courses: payload.content.content.courses, terms: terms, cards: cards,
            weakTermIDs: Set(cards.filter(\.isWeak).map { $0.term.id }), recentOccurrences: occurrences,
            pendingRecords: InboxBrowseIndex(items: records).matching(.init()).active, resumableSession: resumable)
    }
}
