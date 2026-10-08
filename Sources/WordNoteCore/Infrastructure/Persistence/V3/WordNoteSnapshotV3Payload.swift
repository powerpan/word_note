import Foundation
import SwiftData

public struct WordNoteSnapshotV3Payload: Codable, Equatable, Sendable {
    public var content: WordNoteSnapshotV2Payload
    public var termHistories: [TermHistory]
    public var cards: [Card]
    public var sessions: [Session]
    public var sessionItems: [SessionItem]
    public var eventStates: [EventState]

    public var canonicalized: Self {
        var result = self
        result.content = content.canonicalized
        result.termHistories.sort { $0.id.uuidString < $1.id.uuidString }
        result.cards.sort { $0.id.uuidString < $1.id.uuidString }
        result.sessions.sort { $0.id.uuidString < $1.id.uuidString }
        for index in result.sessions.indices {
            result.sessions[index].introductions?.sort { $0.originalCardID.uuidString < $1.originalCardID.uuidString }
        }
        result.sessionItems.sort { $0.id.uuidString < $1.id.uuidString }
        result.eventStates.sort { $0.id.uuidString < $1.id.uuidString }
        return result
    }

    /// This method must run on the context's owning executor. V1/V2 readers reject V3 stores.
    public static func capture(from context: ModelContext,
                               preferences: WordNoteSnapshotPayload.Preferences = .init()) throws -> Self {
        let result = try captureForIntegrityInspection(from: context, preferences: preferences)
        try result.validate()
        return result
    }

    // Only integrity inspection may read invalid relationships; malformed JSON still fails closed.
    static func captureForIntegrityInspection(from context: ModelContext,
                                             preferences: WordNoteSnapshotPayload.Preferences = .init()) throws -> Self {
        guard context.container.schema.version == WordNoteSchemaV3.versionIdentifier else { throw WordNoteSnapshotError.unsupportedSchema }
        let courses = try context.fetch(FetchDescriptor<WordNoteSchemaV3.CourseModel>())
        let records = try context.fetch(FetchDescriptor<WordNoteSchemaV3.InputRecordModel>())
        let candidates = try context.fetch(FetchDescriptor<WordNoteSchemaV3.CandidateTermModel>())
        let terms = try context.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>())
        let events = try context.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewEventModel>())
        let content = WordNoteSnapshotV2Payload(
            content: WordNoteSnapshotPayload(
                courses: courses.map(WordNoteSnapshotPayload.Course.init),
                inputRecords: records.map(WordNoteSnapshotPayload.InputRecord.init),
                candidates: candidates.map(WordNoteSnapshotPayload.Candidate.init),
                terms: terms.map(WordNoteSnapshotPayload.Term.init),
                reviewEvents: events.map(WordNoteSnapshotPayload.ReviewEvent.init), preferences: preferences),
            courseRevisions: courses.map(WordNoteSnapshotV2Payload.CourseRevision.init),
            recordStates: records.map(WordNoteSnapshotV2Payload.RecordState.init),
            candidateStates: candidates.map(WordNoteSnapshotV2Payload.CandidateState.init),
            termStates: terms.map(WordNoteSnapshotV2Payload.TermState.init),
            occurrences: try context.fetch(FetchDescriptor<WordNoteSchemaV3.TermOccurrenceModel>()).map(WordNoteSnapshotV2Payload.Occurrence.init),
            courseLinks: try context.fetch(FetchDescriptor<WordNoteSchemaV3.TermCourseLinkModel>()).map(WordNoteSnapshotV2Payload.CourseLink.init),
            lookupEvents: try context.fetch(FetchDescriptor<WordNoteSchemaV3.LookupEventModel>()).map(WordNoteSnapshotV2Payload.LookupEvent.init))
        return try Self(content: content, termHistories: terms.map(TermHistory.init),
            cards: context.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewCardModel>()).map(Card.init),
            sessions: context.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewSessionModel>()).map(Session.init),
            sessionItems: context.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewSessionItemModel>()).map(SessionItem.init),
            eventStates: events.map(EventState.init)).canonicalized
    }

    public func populateEmptyStore(_ context: ModelContext) throws {
        try populateEmptyStore(context, beforeSave: {})
    }

    // Fault injection remains outside production callers; every successful import still calls save.
    func populateEmptyStore(_ context: ModelContext, beforeSave: () throws -> Void) throws {
        guard context.container.schema.version == WordNoteSchemaV3.versionIdentifier else { throw WordNoteSnapshotError.unsupportedSchema }
        try validate()
        let existingCount = try context.fetchCount(FetchDescriptor<WordNoteSchemaV3.CourseModel>())
            + context.fetchCount(FetchDescriptor<WordNoteSchemaV3.InputRecordModel>())
            + context.fetchCount(FetchDescriptor<WordNoteSchemaV3.CandidateTermModel>())
            + context.fetchCount(FetchDescriptor<WordNoteSchemaV3.TermModel>())
            + context.fetchCount(FetchDescriptor<WordNoteSchemaV3.ReviewEventModel>())
            + context.fetchCount(FetchDescriptor<WordNoteSchemaV3.TermOccurrenceModel>())
            + context.fetchCount(FetchDescriptor<WordNoteSchemaV3.TermCourseLinkModel>())
            + context.fetchCount(FetchDescriptor<WordNoteSchemaV3.LookupEventModel>())
            + context.fetchCount(FetchDescriptor<WordNoteSchemaV3.ReviewCardModel>())
            + context.fetchCount(FetchDescriptor<WordNoteSchemaV3.ReviewSessionModel>())
            + context.fetchCount(FetchDescriptor<WordNoteSchemaV3.ReviewSessionItemModel>())
        guard existingCount == 0, !context.hasChanges else { throw WordNoteSnapshotError.destinationNotEmpty }
        let courses = Dictionary(uniqueKeysWithValues: content.courseRevisions.map { ($0.id, $0) })
        let records = Dictionary(uniqueKeysWithValues: content.recordStates.map { ($0.id, $0) })
        let candidates = Dictionary(uniqueKeysWithValues: content.candidateStates.map { ($0.id, $0) })
        let terms = Dictionary(uniqueKeysWithValues: content.termStates.map { ($0.id, $0) })
        let histories = Dictionary(uniqueKeysWithValues: termHistories.map { ($0.id, $0) })
        let events = Dictionary(uniqueKeysWithValues: eventStates.map { ($0.id, $0) })
        do {
            for value in content.content.courses {
                let model = value.modelV3()
                courses[value.id]?.apply(to: model)
                context.insert(model)
            }
            for value in content.content.inputRecords {
                let model = try value.modelV3()
                records[value.id]?.apply(to: model)
                context.insert(model)
            }
            for value in content.content.candidates {
                let model = try value.modelV3()
                candidates[value.id]?.apply(to: model)
                context.insert(model)
            }
            for value in content.content.terms {
                let model = try value.modelV3()
                terms[value.id]?.apply(to: model)
                histories[value.id]?.apply(to: model)
                context.insert(model)
            }
            for value in content.content.reviewEvents {
                let model = try value.modelV3()
                try events[value.id]?.apply(to: model)
                context.insert(model)
            }
            try content.occurrences.forEach { context.insert(try $0.modelV3()) }
            content.courseLinks.forEach { context.insert($0.modelV3()) }
            try content.lookupEvents.forEach { context.insert(try $0.modelV3()) }
            try cards.forEach { context.insert(try $0.model()) }
            try sessions.forEach { context.insert(try $0.model()) }
            sessionItems.forEach { context.insert($0.model()) }
            try beforeSave()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
