import Foundation
import SwiftData

public struct WordNoteSnapshotV2Payload: Codable, Equatable, Sendable {
    // Reuse the frozen V1 field definitions, with complete one-to-one V2 metadata tables.
    public var content: WordNoteSnapshotPayload
    public var courseRevisions: [CourseRevision]
    public var recordStates: [RecordState]
    public var candidateStates: [CandidateState]
    public var termStates: [TermState]
    public var occurrences: [Occurrence]
    public var courseLinks: [CourseLink]
    public var lookupEvents: [LookupEvent]

    public var canonicalized: Self {
        var result = self
        result.content = content.canonicalized
        result.courseRevisions.sort { $0.id.uuidString < $1.id.uuidString }
        result.recordStates.sort { $0.id.uuidString < $1.id.uuidString }
        result.candidateStates.sort { $0.id.uuidString < $1.id.uuidString }
        result.termStates.sort { $0.id.uuidString < $1.id.uuidString }
        result.occurrences.sort { $0.id.uuidString < $1.id.uuidString }
        result.courseLinks.sort { $0.id.uuidString < $1.id.uuidString }
        result.lookupEvents.sort { $0.id.uuidString < $1.id.uuidString }
        return result
    }

    /// Synchronous access must stay on the context's owning executor.
    public static func capture(
        from context: ModelContext,
        preferences: WordNoteSnapshotPayload.Preferences = .init()
    ) throws -> Self {
        guard context.container.schema.version == WordNoteSchemaV2.versionIdentifier else {
            throw WordNoteSnapshotError.unsupportedSchema
        }
        let courses = try context.fetch(FetchDescriptor<WordNoteSchemaV2.CourseModel>())
        let records = try context.fetch(FetchDescriptor<WordNoteSchemaV2.InputRecordModel>())
        let candidates = try context.fetch(FetchDescriptor<WordNoteSchemaV2.CandidateTermModel>())
        let terms = try context.fetch(FetchDescriptor<WordNoteSchemaV2.TermModel>())
        let events = try context.fetch(FetchDescriptor<WordNoteSchemaV2.ReviewEventModel>())
        let payload = Self(
            content: WordNoteSnapshotPayload(
                courses: courses.map(WordNoteSnapshotPayload.Course.init),
                inputRecords: records.map(WordNoteSnapshotPayload.InputRecord.init),
                candidates: candidates.map(WordNoteSnapshotPayload.Candidate.init),
                terms: terms.map(WordNoteSnapshotPayload.Term.init),
                reviewEvents: events.map(WordNoteSnapshotPayload.ReviewEvent.init),
                preferences: preferences
            ),
            courseRevisions: courses.map(CourseRevision.init),
            recordStates: records.map(RecordState.init),
            candidateStates: candidates.map(CandidateState.init),
            termStates: terms.map(TermState.init),
            occurrences: try context.fetch(FetchDescriptor<WordNoteSchemaV2.TermOccurrenceModel>()).map(Occurrence.init),
            courseLinks: try context.fetch(FetchDescriptor<WordNoteSchemaV2.TermCourseLinkModel>()).map(CourseLink.init),
            lookupEvents: try context.fetch(FetchDescriptor<WordNoteSchemaV2.LookupEventModel>()).map(LookupEvent.init)
        ).canonicalized
        try payload.validate()
        return payload
    }

    public func populateEmptyStore(_ context: ModelContext) throws {
        guard context.container.schema.version == WordNoteSchemaV2.versionIdentifier else {
            throw WordNoteSnapshotError.unsupportedSchema
        }
        try validate()
        let existingCount = try context.fetchCount(FetchDescriptor<WordNoteSchemaV2.CourseModel>())
            + context.fetchCount(FetchDescriptor<WordNoteSchemaV2.InputRecordModel>())
            + context.fetchCount(FetchDescriptor<WordNoteSchemaV2.CandidateTermModel>())
            + context.fetchCount(FetchDescriptor<WordNoteSchemaV2.TermModel>())
            + context.fetchCount(FetchDescriptor<WordNoteSchemaV2.ReviewEventModel>())
            + context.fetchCount(FetchDescriptor<WordNoteSchemaV2.TermOccurrenceModel>())
            + context.fetchCount(FetchDescriptor<WordNoteSchemaV2.TermCourseLinkModel>())
            + context.fetchCount(FetchDescriptor<WordNoteSchemaV2.LookupEventModel>())
        guard existingCount == 0, !context.hasChanges else { throw WordNoteSnapshotError.destinationNotEmpty }
        let courses = Dictionary(uniqueKeysWithValues: courseRevisions.map { ($0.id, $0) })
        let records = Dictionary(uniqueKeysWithValues: recordStates.map { ($0.id, $0) })
        let candidates = Dictionary(uniqueKeysWithValues: candidateStates.map { ($0.id, $0) })
        let terms = Dictionary(uniqueKeysWithValues: termStates.map { ($0.id, $0) })
        do {
            for value in content.courses {
                let model = value.modelV2()
                courses[value.id]?.apply(to: model)
                context.insert(model)
            }
            for value in content.inputRecords {
                let model = try value.modelV2()
                records[value.id]?.apply(to: model)
                context.insert(model)
            }
            for value in content.candidates {
                let model = try value.modelV2()
                candidates[value.id]?.apply(to: model)
                context.insert(model)
            }
            for value in content.terms {
                let model = try value.modelV2()
                terms[value.id]?.apply(to: model)
                context.insert(model)
            }
            try content.reviewEvents.forEach { context.insert(try $0.modelV2()) }
            try occurrences.forEach { context.insert(try $0.model()) }
            courseLinks.forEach { context.insert($0.model()) }
            try lookupEvents.forEach { context.insert(try $0.model()) }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
