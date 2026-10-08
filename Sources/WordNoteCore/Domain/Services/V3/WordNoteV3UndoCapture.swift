import Foundation
import SwiftData

extension WordNoteV3ContentService {
    func undoModels<Model: PersistentModel, Value: Hashable & Codable & Sendable>(
        _ type: Model.Type, matching keyPath: KeyPath<Model, Value> & Sendable, in values: [Value]
    ) throws -> [Model] {
        guard !values.isEmpty else { return [] }
        let predicate = Predicate<Model> { root in
            PredicateExpressions.SequenceContains(
                sequence: PredicateExpressions.Value(values), element: PredicateExpressions.KeyPath(root: root, keyPath: keyPath)
            )
        }
        return try context.fetch(FetchDescriptor<Model>(predicate: predicate))
    }

    private func union<Model: PersistentModel>(_ first: [Model], _ second: [Model]) -> [Model] {
        var seen = Set<PersistentIdentifier>()
        return (first + second).filter { seen.insert($0.persistentModelID).inserted }
    }

    func undoSlice(_ scope: WordNoteV3UndoScope) throws -> WordNoteV3UndoSlice {
        let courseIDs = Array(scope.courses)
        let recordIDs = Array(scope.records)
        let candidateIDs = Array(scope.candidates)
        let termIDs = Array(scope.terms)
        let optionalTerms = termIDs.map(Optional.some)
        let optionalRecords = recordIDs.map(Optional.some)
        let createdCourses = Array(scope.createdCourses)
        let optionalCourses = createdCourses.map(Optional.some)

        let courses = try undoModels(Course.self, matching: \.id, in: courseIDs)
        let records = try undoModels(Record.self, matching: \.id, in: recordIDs)
        let candidates = try undoModels(Candidate.self, matching: \.id, in: candidateIDs)
        let terms = try undoModels(Term.self, matching: \.id, in: termIDs)
        let occurrences = try undoModels(Occurrence.self, matching: \.termID, in: termIDs)
        let links = try undoModels(CourseLink.self, matching: \.termID, in: termIDs)
        let reviews = try undoModels(ReviewEvent.self, matching: \.termID, in: termIDs)
        let occurrenceIDs = occurrences.map { Optional($0.id) }
        let lookups = try union(undoModels(LookupEvent.self, matching: \.termID, in: termIDs),
                                undoModels(LookupEvent.self, matching: \.occurrenceID, in: occurrenceIDs))
        let referencedCandidates = try union(undoModels(Candidate.self, matching: \.savedTermID, in: optionalTerms),
                                             undoModels(Candidate.self, matching: \.inputRecordID, in: recordIDs))
        let sourceTerms = try undoModels(Term.self, matching: \.sourceRecordID, in: optionalRecords)
        let sourceOccurrences = try undoModels(Occurrence.self, matching: \.sourceRecordID, in: optionalRecords)
        let cards = try undoModels(Card.self, matching: \.termID, in: termIDs).map(WordNoteSnapshotV3Payload.Card.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let items = try undoModels(SessionItem.self, matching: \.originalCardID, in: cards.map(\.id))
            .map(WordNoteSnapshotV3Payload.SessionItem.init).sorted { $0.id.uuidString < $1.id.uuidString }
        let sessions = try undoModels(Session.self, matching: \.id, in: Array(Set(items.map(\.sessionID))))
            .map(WordNoteSnapshotV3Payload.Session.init).sorted { $0.id.uuidString < $1.id.uuidString }

        var courseReferences = Set<WordNoteV3UndoSlice.Reference>()
        if !createdCourses.isEmpty {
            let usedTerms = try undoModels(Term.self, matching: \.courseID, in: optionalCourses)
            let usedRecords = try undoModels(Record.self, matching: \.courseID, in: optionalCourses)
            let usedOccurrences = try undoModels(Occurrence.self, matching: \.courseID, in: optionalCourses)
            let usedLinks = try undoModels(CourseLink.self, matching: \.courseID, in: createdCourses)
            courseReferences.formUnion(usedTerms.map { .init(kind: "term", id: $0.id) })
            courseReferences.formUnion(usedRecords.map { .init(kind: "record", id: $0.id) })
            courseReferences.formUnion(usedOccurrences.map { .init(kind: "occurrence", id: $0.id) })
            courseReferences.formUnion(usedLinks.map { .init(kind: "membership", id: $0.id) })
            for session in try fetch(Session.self) {
                let value = try WordNoteSnapshotV3Payload.Session(session)
                if value.scope.courseID.map(scope.createdCourses.contains) == true {
                    courseReferences.insert(.init(kind: "session", id: value.id))
                }
            }
        }
        let values = WordNoteSnapshotV2Payload(
            content: WordNoteSnapshotPayload(
                courses: courses.map(WordNoteSnapshotPayload.Course.init),
                inputRecords: records.map(WordNoteSnapshotPayload.InputRecord.init),
                candidates: candidates.map(WordNoteSnapshotPayload.Candidate.init),
                terms: terms.map(WordNoteSnapshotPayload.Term.init),
                reviewEvents: reviews.map(WordNoteSnapshotPayload.ReviewEvent.init), preferences: .init()
            ),
            courseRevisions: courses.map(WordNoteSnapshotV2Payload.CourseRevision.init),
            recordStates: records.map(WordNoteSnapshotV2Payload.RecordState.init),
            candidateStates: candidates.map(WordNoteSnapshotV2Payload.CandidateState.init),
            termStates: terms.map(WordNoteSnapshotV2Payload.TermState.init),
            occurrences: occurrences.map(WordNoteSnapshotV2Payload.Occurrence.init),
            courseLinks: links.map(WordNoteSnapshotV2Payload.CourseLink.init),
            lookupEvents: lookups.map(WordNoteSnapshotV2Payload.LookupEvent.init)
        ).canonicalized
        return WordNoteV3UndoSlice(
            values: values,
            candidateReferences: Set(referencedCandidates.map {
                .init(id: $0.id, revision: $0.revision, recordID: $0.inputRecordID, termID: $0.savedTermID, linkState: $0.savedLinkStateRaw)
            }), sourceTerms: Set(sourceTerms.map(\.id)), sourceOccurrences: Set(sourceOccurrences.map(\.id)),
            createdCourseReferences: courseReferences,
            review: .init(histories: terms.map(WordNoteSnapshotV3Payload.TermHistory.init).sorted { $0.id.uuidString < $1.id.uuidString },
                cards: cards, events: try reviews.map(WordNoteSnapshotV3Payload.EventState.init).sorted { $0.id.uuidString < $1.id.uuidString },
                sessions: sessions, items: items)
        )
    }

    func validateUndoReferences(_ receipt: WordNoteV3UndoReceipt) throws {
        let before = receipt.before.values
        let scope = receipt.scope
        let courseIDs = Set(before.courseLinks.map(\.courseID))
            .union(before.occurrences.compactMap(\.courseID))
            .union(before.content.terms.compactMap(\.courseID))
            .union(before.content.inputRecords.compactMap(\.courseID))
        let recordIDs = Set(before.occurrences.compactMap(\.sourceRecordID))
            .union(before.content.terms.compactMap(\.sourceRecordID))
            .union(before.content.candidates.map(\.inputRecordID))
        let savedTermIDs = Set(before.candidateStates.compactMap(\.savedTermID))
        guard try courseIDs == Set(undoModels(Course.self, matching: \.id, in: Array(courseIDs)).map(\.id)),
              try recordIDs == Set(undoModels(Record.self, matching: \.id, in: Array(recordIDs)).map(\.id)),
              try savedTermIDs == Set(undoModels(Term.self, matching: \.id, in: Array(savedTermIDs)).map(\.id)) else {
            throw WordNoteV3UndoError.changedSinceSave
        }
        let restoredNames = Set(before.content.terms.map(\.normalizedTerm))
        guard try !undoModels(Term.self, matching: \.normalizedTerm, in: Array(restoredNames))
            .contains(where: { !scope.terms.contains($0.id) }) else {
            throw WordNoteV3UndoError.changedSinceSave
        }
        let oldLinkIDs = Set(before.courseLinks.map(\.id))
        let oldOccurrenceIDs = Set(before.occurrences.map(\.id))
        guard try !undoModels(CourseLink.self, matching: \.id, in: Array(oldLinkIDs)).contains(where: { !scope.terms.contains($0.termID) }),
              try !undoModels(Occurrence.self, matching: \.id, in: Array(oldOccurrenceIDs)).contains(where: { !scope.terms.contains($0.termID) }) else {
            throw WordNoteV3UndoError.changedSinceSave
        }
    }
}
