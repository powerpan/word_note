import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2DeletionTests: XCTestCase {
    private typealias Support = WordNoteV2ServiceTestSupport

    func testDeletingInputPreservesTermAndOccurrenceTextButRemovesCandidatesAndLiveReferences() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let candidate = try Support.candidate("throughput", in: container)
        let recordID = candidate.inputRecordID
        let created = try service.confirmCandidate(candidate.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: UUID(), target: .createNew, at: Support.now)
        let before = try Support.snapshot(container)
        let source = try XCTUnwrap(before.occurrences.first)
        try service.deleteInputRecord(recordID, expectedRevision: 1, at: Support.now.addingTimeInterval(1))
        let after = try Support.snapshot(container)
        XCTAssertFalse(after.content.inputRecords.contains { $0.id == recordID })
        XCTAssertFalse(after.content.candidates.contains { $0.inputRecordID == recordID })
        let term = try XCTUnwrap(after.content.terms.first { $0.id == created.id })
        XCTAssertEqual(term.term, "throughput")
        XCTAssertEqual(term.contextSentence, source.rawTextSnapshot)
        XCTAssertNil(term.sourceRecordID)
        XCTAssertEqual(after.content.reviewEvents, before.content.reviewEvents)
        XCTAssertEqual(after.courseLinks, before.courseLinks)
        let preserved = try XCTUnwrap(after.occurrences.first { $0.id == source.id })
        XCTAssertEqual(preserved.rawTextSnapshot, source.rawTextSnapshot)
        XCTAssertEqual(preserved.captureID, source.captureID)
        XCTAssertEqual(preserved.courseID, source.courseID)
        XCTAssertNil(preserved.sourceRecordID)
        XCTAssertEqual(after.termStates.first { $0.id == term.id }?.revision, 1)
    }

    func testDeletingOccurrenceKeepsLookupEventButDetachesItAndDoesNotResurrectSourceOnReplay() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let request = WordNoteCaptureRequest(rawText: "quick")
        _ = try service.capture(request, at: Support.now)
        let source = try XCTUnwrap(Support.snapshot(container).occurrences.first)
        try service.deleteOccurrence(source.id, expectedTermRevision: 1, at: Support.now.addingTimeInterval(1))
        let after = try Support.snapshot(container)
        XCTAssertTrue(after.occurrences.isEmpty)
        XCTAssertEqual(after.lookupEvents.count, 1)
        XCTAssertNil(after.lookupEvents[0].occurrenceID)
        XCTAssertEqual(try Support.term("quick", in: container).revision, 2)
        XCTAssertThrowsError(try service.capture(request, at: Support.now.addingTimeInterval(2))) {
            XCTAssertEqual($0 as? WordNoteV2ContentError, .captureConflict)
        }
        XCTAssertEqual(try Support.snapshot(container), after)
    }

    func testDeletingTermCascadesV2RelationsAndReviewHistoryAndMarksSavedTargetDeleted() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let candidate = try Support.candidate("quick", in: container)
        let term = try Support.term("quick", in: container)
        let termID = term.id
        let candidateID = candidate.id
        let operation = UUID()
        _ = try service.confirmCandidate(candidateID, expectedRevision: 0, expectedRecordRevision: 0, operationID: operation, target: .linkExisting(termID: termID, expectedRevision: 0), at: Support.now)
        _ = try service.capture(.init(rawText: "quick"), at: Support.now.addingTimeInterval(1))
        try service.deleteTerm(termID, expectedRevision: 2, at: Support.now.addingTimeInterval(2))
        let snapshot = try Support.snapshot(container)
        XCTAssertFalse(snapshot.content.terms.contains { $0.id == termID })
        XCTAssertFalse(snapshot.content.reviewEvents.contains { $0.termID == termID })
        XCTAssertFalse(snapshot.occurrences.contains { $0.termID == termID })
        XCTAssertFalse(snapshot.courseLinks.contains { $0.termID == termID })
        XCTAssertFalse(snapshot.lookupEvents.contains { $0.termID == termID })
        let state = try XCTUnwrap(snapshot.candidateStates.first { $0.id == candidateID })
        XCTAssertEqual(state.savedLinkStateRaw, "targetDeleted")
        XCTAssertNil(state.savedTermID)
        XCTAssertEqual(state.confirmationOperationID, operation)
        XCTAssertEqual(state.revision, 2)
        XCTAssertEqual(snapshot.content.candidates.first { $0.id == candidateID }?.statusRaw, "saved")
        XCTAssertThrowsError(try service.confirmCandidate(candidateID, expectedRevision: 0, expectedRecordRevision: 0, operationID: operation, target: .createNew, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV2ContentError, .savedTargetDeleted)
        }
        XCTAssertEqual(try Support.snapshot(container), snapshot)
    }

    func testRemovingMembershipPreservesHistoricalCourseAndProtectsCourseDeletion() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let course = try service.createCourse(courseName: "Encounter course", at: Support.now)
        let term = try Support.term("quick", in: container)
        _ = try service.capture(.init(rawText: "quick", courseID: course.id), at: Support.now)
        _ = try service.setCourseMembership(termID: term.id, courseID: course.id, included: false, expectedTermRevision: 1, at: Support.now)
        let usage = try service.courseUsage(course.id)
        XCTAssertEqual(usage, WordNoteV2CourseUsage(inputRecords: 0, memberships: 0, occurrences: 1))
        XCTAssertThrowsError(try service.deleteCourse(course.id, expectedRevision: 0, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV2ContentError, .courseInUse(usage))
        }
        let source = try XCTUnwrap(Support.snapshot(container).occurrences.first)
        XCTAssertEqual(source.courseID, course.id)
        try service.deleteOccurrence(source.id, expectedTermRevision: 2, at: Support.now)
        try service.deleteCourse(course.id, expectedRevision: 0, at: Support.now)
        XCTAssertFalse(try Support.snapshot(container).content.courses.contains { $0.id == course.id })
    }

    func testCourseDeletionSeparatelyProtectsPendingInputsAndMemberships() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let course = try service.createCourse(courseName: "New course", at: Support.now)
        let input = try service.capture(.init(rawText: "new input", courseID: course.id), analyze: false, at: Support.now)
        XCTAssertEqual(try service.courseUsage(course.id), WordNoteV2CourseUsage(inputRecords: 1, memberships: 0, occurrences: 0))
        XCTAssertThrowsError(try service.deleteCourse(course.id, expectedRevision: 0, at: Support.now))
        try service.deleteInputRecord(Support.inputID(input), expectedRevision: 0, at: Support.now)
        let term = try Support.term("quick", in: container)
        _ = try service.setCourseMembership(termID: term.id, courseID: course.id, included: true, expectedTermRevision: 0, at: Support.now)
        XCTAssertEqual(try service.courseUsage(course.id), WordNoteV2CourseUsage(inputRecords: 0, memberships: 1, occurrences: 0))
        XCTAssertThrowsError(try service.deleteCourse(course.id, expectedRevision: 0, at: Support.now))
        _ = try service.setCourseMembership(termID: term.id, courseID: course.id, included: false, expectedTermRevision: 1, at: Support.now)
        try service.deleteCourse(course.id, expectedRevision: 0, at: Support.now)
        XCTAssertNoThrow(try Support.snapshot(container))
    }

    func testCourseDeletionClearsOnlyLegacyReferenceWhenNoAuthoritativeReferencesRemain() throws {
        let container = try Support.container(populated: false)
        let service = try WordNoteV2ContentService(container: container)
        let course = try service.createCourse(courseName: "Legacy only", at: Support.now)
        let term = WordNoteSchemaV2.TermModel(term: "legacy", termType: .word, chineseMeaning: "遺產", courseID: course.id)
        container.mainContext.insert(term)
        try container.mainContext.save()
        XCTAssertFalse(try service.courseUsage(course.id).isInUse)
        try service.deleteCourse(course.id, expectedRevision: 0, at: Support.now)
        XCTAssertNil(term.courseID)
        XCTAssertEqual(term.revision, 1)
        XCTAssertEqual(term.chineseMeaning, "遺產")
        XCTAssertNoThrow(try Support.snapshot(container))
    }

    func testMembershipIsUniqueAndDoesNotRewriteLegacyCourseOrDefinitions() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let term = try Support.term("quick", in: container)
        let oldCourse = term.courseID
        let oldMeaning = term.chineseMeaning
        let courseID = try Support.snapshot(container).content.courses[1].id
        let first = try service.setCourseMembership(termID: term.id, courseID: courseID, included: true, expectedTermRevision: 0, at: Support.now)
        let repeated = try service.setCourseMembership(termID: term.id, courseID: courseID, included: true, expectedTermRevision: 1, at: Support.now)
        XCTAssertEqual(first, repeated)
        XCTAssertEqual(term.courseID, oldCourse)
        XCTAssertEqual(term.chineseMeaning, oldMeaning)
        XCTAssertEqual(try Support.snapshot(container).courseLinks.filter { $0.termID == term.id && $0.courseID == courseID }.count, 1)
        XCTAssertThrowsError(try service.setCourseMembership(termID: term.id, courseID: courseID, included: false, expectedTermRevision: 0, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV2ContentError, .revisionConflict(expected: 0, actual: 1))
        }
    }

    func testEveryDeleteRejectsStaleRevisionWithoutChangingAnything() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        _ = try service.capture(.init(rawText: "quick"), at: Support.now)
        let before = try Support.snapshot(container)
        let term = try Support.term("quick", in: container)
        XCTAssertThrowsError(try service.deleteTerm(term.id, expectedRevision: 0, at: Support.now))
        XCTAssertThrowsError(try service.deleteOccurrence(before.occurrences[0].id, expectedTermRevision: 0, at: Support.now))
        XCTAssertThrowsError(try service.deleteInputRecord(before.content.inputRecords[0].id, expectedRevision: 1, at: Support.now))
        XCTAssertThrowsError(try service.deleteCourse(before.content.courses[0].id, expectedRevision: 1, at: Support.now))
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testDeletionSaveFailuresRestoreAllRelationsAndStates() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let candidate = try Support.candidate("quick", in: container)
        let recordID = candidate.inputRecordID
        let term = try Support.term("quick", in: container)
        _ = try service.confirmCandidate(candidate.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: UUID(), target: .linkExisting(termID: term.id, expectedRevision: 0), at: Support.now)
        _ = try service.capture(.init(rawText: "quick"), at: Support.now)
        let unusedCourse = try service.createCourse(courseName: "Unused", at: Support.now)
        let before = try Support.snapshot(container)
        let failing = try WordNoteV2ContentService(container: container, save: { _ in throw Support.Failure.save })
        let mutations: [() throws -> Void] = [
            { try failing.deleteTerm(term.id, expectedRevision: 2, at: Support.now) },
            { try failing.deleteInputRecord(recordID, expectedRevision: 1, at: Support.now) },
            { try failing.deleteOccurrence(before.occurrences[0].id, expectedTermRevision: 2, at: Support.now) },
            { try failing.deleteCourse(unusedCourse.id, expectedRevision: 0, at: Support.now) }
        ]
        for mutate in mutations {
            XCTAssertThrowsError(try mutate()) { XCTAssertEqual($0 as? Support.Failure, .save) }
            XCTAssertEqual(try Support.snapshot(container), before)
            XCTAssertFalse(container.mainContext.hasChanges)
        }
    }

    func testCourseAndMembershipFailuresRollBackWithoutExtraRows() throws {
        let container = try Support.container()
        let before = try Support.snapshot(container)
        let failing = try WordNoteV2ContentService(container: container, save: { _ in throw Support.Failure.save })
        let term = try Support.term("quick", in: container)
        XCTAssertThrowsError(try failing.createCourse(courseName: "New course", at: Support.now)) {
            XCTAssertEqual($0 as? Support.Failure, .save)
        }
        XCTAssertThrowsError(try failing.setCourseMembership(termID: term.id, courseID: before.content.courses[1].id, included: true, expectedTermRevision: 0, at: Support.now)) {
            XCTAssertEqual($0 as? Support.Failure, .save)
        }
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testRestoreGateBlocksEveryV2MutationBeforeValidationOrInsertion() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let before = try Support.snapshot(container)
        let gate = try WordNoteWriteGate.beginRestore(container.mainContext)
        let mutations: [() throws -> Void] = [
            { _ = try service.capture(.init(rawText: "new"), at: Support.now) },
            { _ = try service.createCourse(courseName: "New", at: Support.now) },
            { _ = try service.setCourseMembership(termID: UUID(), courseID: UUID(), included: true, expectedTermRevision: 0, at: Support.now) },
            { _ = try service.createManualTerm(sourceRecordID: UUID(), expectedRecordRevision: 0, termText: "new", chineseMeaning: "新", englishDefinition: nil, at: Support.now) },
            { _ = try service.confirmCandidate(UUID(), expectedRevision: 0, expectedRecordRevision: 0, operationID: UUID(), target: .createNew, at: Support.now) },
            { try service.deleteTerm(UUID(), expectedRevision: 0, at: Support.now) },
            { try service.deleteInputRecord(UUID(), expectedRevision: 0, at: Support.now) },
            { try service.deleteOccurrence(UUID(), expectedTermRevision: 0, at: Support.now) },
            { try service.deleteCourse(UUID(), expectedRevision: 0, at: Support.now) }
        ]
        for mutate in mutations {
            XCTAssertThrowsError(try mutate()) { XCTAssertEqual($0 as? WordNoteWriteError, .restoreInProgress) }
        }
        XCTAssertEqual(try Support.snapshot(container), before)
        try WordNoteWriteGate.endRestore(container.mainContext, ticket: gate)
    }

    func testV2ServiceCannotAttachToProductionV1Container() throws {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        XCTAssertThrowsError(try WordNoteV2ContentService(container: container)) {
            XCTAssertEqual($0 as? WordNoteV2ContentError, .wrongSchema)
        }
    }
}
