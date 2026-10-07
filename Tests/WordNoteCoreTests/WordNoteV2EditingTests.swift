import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2EditingTests: XCTestCase {
    private typealias Support = WordNoteV2ServiceTestSupport

    func testCandidateDraftIsDetachedAndSaveChecksBothRevisions() throws {
        let container = try Support.container()
        let candidate = try Support.candidate("throughput", in: container)
        let record = try Support.record(candidate.inputRecordID, in: container)
        var draft = WordNoteV2CandidateEdit(candidate, recordRevision: record.revision)
        draft.chineseMeaning = "Updated meaning"
        XCTAssertFalse(container.mainContext.hasChanges)
        XCTAssertNotEqual(candidate.chineseMeaning, draft.chineseMeaning)
        let service = try WordNoteV2ContentService(container: container)
        try service.updateCandidate(draft, at: Support.now)
        XCTAssertEqual(candidate.chineseMeaning, "Updated meaning")
        XCTAssertEqual(candidate.revision, 1)
        XCTAssertEqual(record.revision, 1)
        let after = try Support.snapshot(container)
        XCTAssertThrowsError(try service.updateCandidate(draft, at: Support.now))
        XCTAssertEqual(try Support.snapshot(container), after)
    }

    func testCandidateEditsRejectChineseHeadwordMissingMeaningAndActiveAnalysis() throws {
        let container = try Support.container()
        let candidate = try Support.candidate("overfitting", in: container)
        let record = try Support.record(candidate.inputRecordID, in: container)
        let service = try WordNoteV2ContentService(container: container)
        let before = try Support.snapshot(container)
        var edit = WordNoteV2CandidateEdit(candidate, recordRevision: record.revision)
        edit.term = "過擬合"
        XCTAssertThrowsError(try service.updateCandidate(edit))
        edit.term = "overfitting"
        edit.chineseMeaning = ""
        edit.englishDefinition = "A definition"
        XCTAssertThrowsError(try service.updateCandidate(edit))
        XCTAssertEqual(try Support.snapshot(container), before)
        _ = try service.queueAnalysis(record.id, expectedRevision: record.revision)
        edit = WordNoteV2CandidateEdit(candidate, recordRevision: record.revision)
        XCTAssertThrowsError(try service.updateCandidate(edit))
    }

    func testCandidateEditFailureRollsBackFieldsAndBothRevisions() throws {
        let container = try Support.container()
        let before = try Support.snapshot(container)
        let candidate = try Support.candidate("throughput", in: container)
        var draft = WordNoteV2CandidateEdit(candidate, recordRevision: 0)
        draft.term = "throughput rate"
        let service = try WordNoteV2ContentService(container: container, save: { _ in throw Support.Failure.save })
        XCTAssertThrowsError(try service.updateCandidate(draft))
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testTermEditUpdatesAllMembershipsWithoutChangingOriginsOrReviewHistory() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        _ = try service.capture(.init(rawText: "quick", capturedVia: .floatingQuickAdd), at: Support.now)
        let term = try Support.term("quick", in: container)
        let before = try Support.snapshot(container)
        let ids = Set(before.content.courses.map(\.id))
        try update(term, using: service, revision: term.revision, courses: ids)
        let after = try Support.snapshot(container)
        XCTAssertEqual(after.occurrences, before.occurrences)
        XCTAssertEqual(after.lookupEvents, before.lookupEvents)
        XCTAssertEqual(after.content.reviewEvents, before.content.reviewEvents)
        XCTAssertEqual(term.chineseMeaning, "Edited meaning")
        XCTAssertEqual(term.reviewCount, before.content.terms.first { $0.id == term.id }?.reviewCount)
        XCTAssertEqual(Set(after.courseLinks.filter { $0.termID == term.id }.map(\.courseID)), ids)
        XCTAssertEqual(term.courseID, before.content.terms.first { $0.id == term.id }?.courseID)
    }

    func testTermEditRejectsStaleDuplicateMissingCourseAndInvalidSubjectAtomically() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let term = try Support.term("quick", in: container)
        let before = try Support.snapshot(container)
        XCTAssertThrowsError(try update(term, using: service, revision: 1))
        XCTAssertThrowsError(try update(term, using: service, revision: 0, text: "overfitting"))
        XCTAssertThrowsError(try update(term, using: service, revision: 0, text: "中文"))
        XCTAssertThrowsError(try update(term, using: service, revision: 0, courses: [UUID()]))
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testTermSaveFailureRollsBackMembershipRemovalsAndFields() throws {
        let container = try Support.container()
        let term = try Support.term("quick", in: container)
        let before = try Support.snapshot(container)
        let service = try WordNoteV2ContentService(container: container, save: { _ in throw Support.Failure.save })
        XCTAssertThrowsError(try update(term, using: service, revision: 0))
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testCourseEditTrimsAndRejectsStaleOrBlankWrites() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let course = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV2.CourseModel>()).first)
        try service.updateCourse(course.id, expectedRevision: 0, courseName: " Revised ", courseCode: " ", instructor: nil, semester: nil, description: nil, at: Support.now)
        XCTAssertEqual(course.courseName, "Revised")
        XCTAssertNil(course.courseCode)
        XCTAssertEqual(course.revision, 1)
        let after = try Support.snapshot(container)
        XCTAssertThrowsError(try service.updateCourse(course.id, expectedRevision: 0, courseName: "Stale", courseCode: nil, instructor: nil, semester: nil, description: nil))
        XCTAssertThrowsError(try service.updateCourse(course.id, expectedRevision: 1, courseName: " ", courseCode: nil, instructor: nil, semester: nil, description: nil))
        XCTAssertEqual(try Support.snapshot(container), after)
    }

    func testBatchDuplicateRollsBackPreviouslyCreatedTermsAndRelations() throws {
        let container = try Support.container()
        let before = try Support.snapshot(container)
        let service = try WordNoteV2ContentService(container: container)
        XCTAssertThrowsError(try service.confirmNewCandidates(selections(["throughput", "quick"], in: container)))
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testBatchConfirmsMultipleCandidatesFromOneRecordInOneSave() throws {
        let container = try Support.container()
        let quick = try Support.candidate("quick", in: container)
        let setup = try WordNoteV2ContentService(container: container)
        var draft = WordNoteV2CandidateEdit(quick, recordRevision: 0)
        draft.term = "latency"
        try setup.updateCandidate(draft)
        var saves = 0
        let service = try WordNoteV2ContentService(container: container, save: { saves += 1; try $0.save() })
        let result = try service.confirmNewCandidates(selections(["latency", "throughput"], in: container), at: Support.now)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try Support.record(quick.inputRecordID, in: container).status, .completed)
        XCTAssertEqual(try Support.snapshot(container).occurrences.count, 2)
    }

    func testIgnoreChecksWholeSelectionAndPreservesAlreadySavedCandidateLinks() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let chosen = try selections(["throughput"], in: container)
        _ = try service.confirmNewCandidates(chosen)
        let saved = try Support.candidate("throughput", in: container)
        let savedID = saved.savedTermID
        let record = try Support.record(saved.inputRecordID, in: container)
        try service.ignoreInputRecord(record.id, expectedRevision: record.revision)
        XCTAssertEqual(saved.savedTermID, savedID)
        XCTAssertEqual(saved.status, .saved)
        XCTAssertEqual(try Support.candidate("quick", in: container).status, .ignored)
        XCTAssertEqual(record.status, .ignored)
        XCTAssertEqual(record.queueStateRaw, "none")
        XCTAssertNoThrow(try Support.snapshot(container))
    }

    func testBatchIgnoreRejectsAnyStaleSelectionAndSaveFailure() throws {
        let container = try Support.container()
        let before = try Support.snapshot(container)
        let chosen = try selections(["quick", "throughput"], in: container)
        let invalid = chosen + [.init(id: UUID(), revision: 0, recordID: chosen[0].recordID, recordRevision: 0)]
        let service = try WordNoteV2ContentService(container: container)
        XCTAssertThrowsError(try service.ignoreCandidates(invalid))
        let failing = try WordNoteV2ContentService(container: container, save: { _ in throw Support.Failure.save })
        XCTAssertThrowsError(try failing.ignoreCandidates(chosen))
        XCTAssertEqual(try Support.snapshot(container), before)
        try service.ignoreCandidates(chosen, at: Support.now)
        XCTAssertEqual(try Support.record(chosen[0].recordID, in: container).status, .completed)
    }

    func testRestoreGateAndDirtyContextBlockAllNewEditPaths() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let term = try Support.term("quick", in: container)
        let candidate = try Support.candidate("throughput", in: container)
        let draft = WordNoteV2CandidateEdit(candidate, recordRevision: 0)
        let ticket = try WordNoteWriteGate.beginRestore(container.mainContext)
        XCTAssertThrowsError(try service.updateCandidate(draft))
        XCTAssertThrowsError(try update(term, using: service, revision: 0))
        XCTAssertThrowsError(try service.ignoreCandidates(selections(["throughput"], in: container)))
        try WordNoteWriteGate.endRestore(container.mainContext, ticket: ticket)
        term.chineseMeaning = "Uncommitted external edit"
        XCTAssertThrowsError(try service.updateCandidate(draft)) { XCTAssertEqual($0 as? WordNoteV2ContentError, .unsavedChanges) }
        XCTAssertEqual(term.chineseMeaning, "Uncommitted external edit")
        container.mainContext.rollback()
    }

    private func selections(_ names: [String], in container: ModelContainer) throws -> [WordNoteV2CandidateSelection] {
        try names.map { name in
            let candidate = try Support.candidate(name, in: container)
            let record = try Support.record(candidate.inputRecordID, in: container)
            return .init(id: candidate.id, revision: candidate.revision, recordID: record.id, recordRevision: record.revision)
        }
    }

    private func update(
        _ term: WordNoteSchemaV2.TermModel, using service: WordNoteV2ContentService,
        revision: Int, text: String = "quick", courses: Set<UUID> = []
    ) throws {
        try service.updateTerm(
            term.id, expectedRevision: revision, termText: text, termType: .word, chineseMeaning: "Edited meaning",
            englishDefinition: nil, aiContextExplanation: nil, exampleSentence: nil, contextSentence: "Edited context",
            courseIDs: courses, sourceType: .other, category: .general, importance: .medium, masteryLevel: .familiar, at: Support.now
        )
    }
}
