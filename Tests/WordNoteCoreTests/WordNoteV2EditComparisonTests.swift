import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2EditComparisonTests: XCTestCase {
    private typealias Support = WordNoteV2ServiceTestSupport
    private typealias Candidate = WordNoteSchemaV2.CandidateTermModel

    func testTermRebaseDoesNotWriteAndUndoPreservesEarlierExternalEdit() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let id = try Support.term("quick", in: container).id
        let initial = try service.termDraftVersion(id)
        let draft = WordNoteEditDraft(initial.value, revision: initial.revision)
        draft.value.chineseMeaning = "我的修改"
        var remote = initial.value; remote.englishDefinition = "Remote English definition"
        try saveTerm(remote, id: id, revision: initial.revision, using: service)
        let current = try service.termDraftVersion(id)
        let before = try Support.snapshot(container)
        let receipt = history.operationID
        let comparison = try WordNoteEditComparison(draft: draft, current: current, fields: WordNoteTermEditValues.comparisonFields(courseNames: [:]))
        try comparison.apply(to: draft, latest: service.termDraftVersion(id), choices: [:])
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertEqual(history.operationID, receipt)
        XCTAssertFalse(container.mainContext.hasChanges)
        XCTAssertEqual(draft.value.englishDefinition, remote.englishDefinition)
        try saveTerm(draft.value, id: id, revision: draft.revision, using: service)
        XCTAssertEqual(try Support.term("quick", in: container).chineseMeaning, "我的修改")
        try history.undo()
        let restored = try service.termDraftVersion(id)
        XCTAssertEqual(restored.value, current.value)
        XCTAssertGreaterThan(restored.revision, current.revision)
    }

    func testAnotherWriteAfterRebaseStillPreventsSave() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let id = try Support.term("quick", in: container).id
        let initial = try service.termDraftVersion(id)
        let draft = WordNoteEditDraft(initial.value, revision: initial.revision)
        draft.value.chineseMeaning = "Local meaning"
        var remote = initial.value; remote.englishDefinition = "First update"
        try saveTerm(remote, id: id, revision: initial.revision, using: service)
        let current = try service.termDraftVersion(id)
        let comparison = try WordNoteEditComparison(draft: draft, current: current, fields: WordNoteTermEditValues.comparisonFields(courseNames: [:]))
        try comparison.apply(to: draft, latest: current, choices: [:])
        remote.englishDefinition = "Second update"
        try saveTerm(remote, id: id, revision: current.revision, using: service)
        let before = try Support.snapshot(container)
        XCTAssertThrowsError(try saveTerm(draft.value, id: id, revision: draft.revision, using: service))
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertTrue(draft.isDirty)
    }

    func testCourseRebaseKeepsRemoteCodeAndLocalDescription() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let created = try service.createCourse(courseName: "Synthetic Course")
        let initial = try service.courseDraftVersion(created.id)
        let draft = WordNoteEditDraft(initial.value, revision: initial.revision)
        draft.value.description = "Local description"
        try service.updateCourse(created.id, expectedRevision: initial.revision, courseName: initial.value.courseName,
                                  courseCode: "REMOTE", instructor: nil, semester: nil, description: nil)
        let current = try service.courseDraftVersion(created.id)
        let comparison = try WordNoteEditComparison(draft: draft, current: current, fields: WordNoteCourseEditValues.comparisonFields)
        try comparison.apply(to: draft, latest: current, choices: [:])
        XCTAssertEqual(draft.value.courseCode, "REMOTE")
        try service.updateCourse(created.id, expectedRevision: draft.revision, courseName: draft.value.courseName,
                                  courseCode: draft.value.courseCode, instructor: draft.value.instructor,
                                  semester: draft.value.semester, description: draft.value.description)
        XCTAssertEqual(try service.courseDraftVersion(created.id).value, draft.value)
    }

    func testCandidateRebaseUsesFreshCandidateAndSharedRecordRevisions() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let candidate = try Support.candidate("throughput", in: container)
        let initial = try service.candidateDraftVersion([candidate.id], sourceRecordID: candidate.inputRecordID)
        let draft = WordNoteEditDraft(initial.value, revision: initial.revision)
        draft.value[0].chineseMeaning = "本地釋義"
        var remote = initial.value[0]; remote.englishDefinition = "Remote meaning"
        try service.updateCandidate(remote)
        let current = try service.candidateDraftVersion(initial.value.map(\.id), sourceRecordID: candidate.inputRecordID)
        let before = try Support.snapshot(container)
        let comparison = try WordNoteEditComparison(draft: draft, current: current, fields: WordNoteV2CandidateEdit.comparisonFields(for: initial.value))
        try comparison.apply(to: draft, latest: current, choices: [:])
        XCTAssertEqual(try Support.snapshot(container), before)
        let changed = draft.value.filter { value in draft.baseline.first(where: { $0.id == value.id }) != value }
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed[0].recordRevision, 1)
        XCTAssertEqual(changed[0].revision, 1)
        try service.updateCandidates(changed)
        XCTAssertEqual(candidate.chineseMeaning, "本地釋義")
        XCTAssertEqual(candidate.englishDefinition, "Remote meaning")
        XCTAssertEqual(candidate.revision, 2)
        XCTAssertEqual(try Support.record(candidate.inputRecordID, in: container).revision, 2)
    }

    func testCandidateFieldsResolveByIDRatherThanArrayPosition() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let candidate = try Support.candidate("throughput", in: container)
        let initial = try service.candidateDraftVersion([candidate.id], sourceRecordID: candidate.inputRecordID)
        let draft = WordNoteEditDraft(initial.value)
        draft.value[0].term = "throughput rate"
        draft.value[0].importance = .high
        draft.value[0].category = TermCategory.allCases.first { $0 != initial.value[0].category }!
        draft.value[0].chineseMeaning = "吞吐率"
        draft.value[0].englishDefinition = "Local definition"
        draft.value[0].aiContextExplanation = "Local context"
        draft.value[0].exampleSentence = "Local example"
        let current = WordNoteDraftVersion(Array(initial.value.reversed()), revision: initial.revision)
        let comparison = try WordNoteEditComparison(draft: draft, current: current, fields: WordNoteV2CandidateEdit.comparisonFields(for: initial.value))
        let result = try comparison.resolvedValue(choices: [:])
        XCTAssertFalse(comparison.differences.contains { $0.id == "candidates" }, "Renaming is not a candidate identity change")
        XCTAssertEqual(result.first { $0.id == candidate.id }, draft.value.first { $0.id == candidate.id })
        XCTAssertEqual(result.first { $0.id != candidate.id }, initial.value.first { $0.id != candidate.id })
    }

    func testConfirmedCandidateRemainsReadableButCannotBeRebasedOrRevived() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let candidate = try Support.candidate("throughput", in: container)
        let initial = try service.candidateDraftVersion([candidate.id], sourceRecordID: candidate.inputRecordID)
        let draft = WordNoteEditDraft(initial.value)
        draft.value[0].chineseMeaning = "Unsaved local meaning"
        _ = try service.confirmCandidate(candidate.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: UUID(), target: .createNew)
        let current = try service.candidateDraftVersion(initial.value.map(\.id), sourceRecordID: candidate.inputRecordID)
        XCTAssertNotNil(current.blockingMessage)
        XCTAssertTrue(current.value.contains { $0.id == candidate.id })
        let before = try Support.snapshot(container)
        let comparison = try WordNoteEditComparison(draft: draft, current: current, fields: WordNoteV2CandidateEdit.comparisonFields(for: initial.value))
        XCTAssertThrowsError(try comparison.apply(to: draft, latest: current, choices: [:]))
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertEqual(candidate.status, .saved)
        XCTAssertTrue(draft.isDirty)
    }

    func testQueuedAndRunningAnalysisBlockCandidateRebase() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let candidate = try Support.candidate("throughput", in: container)
        let sourceID = candidate.inputRecordID
        let queued = try service.queueAnalysis(sourceID, expectedRevision: 0)
        XCTAssertNotNil(try service.candidateDraftVersion([candidate.id], sourceRecordID: sourceID).blockingMessage)
        _ = try service.beginAnalysis(sourceID, expectedRevision: queued.revision)
        XCTAssertNotNil(try service.candidateDraftVersion([candidate.id], sourceRecordID: sourceID).blockingMessage)
    }

    func testNewCandidateInvalidatesOldPreviewAndIsPreservedAfterRefresh() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let candidate = try Support.candidate("throughput", in: container)
        let initial = try service.candidateDraftVersion([candidate.id], sourceRecordID: candidate.inputRecordID)
        let draft = WordNoteEditDraft(initial.value)
        draft.value[0].chineseMeaning = "Local meaning"
        let fields = WordNoteV2CandidateEdit.comparisonFields(for: initial.value)
        let oldPreview = try WordNoteEditComparison(draft: draft, current: initial, fields: fields)
        let added = Candidate(inputRecordID: candidate.inputRecordID, term: "latency", termType: .word,
                               needToLearn: true, importance: .medium, category: .general, chineseMeaning: "延遲")
        let source = try Support.record(candidate.inputRecordID, in: container)
        added.analysisGeneration = source.analysisGeneration
        source.revision += 1
        container.mainContext.insert(added)
        try container.mainContext.save()
        let current = try service.candidateDraftVersion(initial.value.map(\.id), sourceRecordID: source.id)
        XCTAssertThrowsError(try oldPreview.apply(to: draft, latest: current, choices: [:]))
        let refreshed = try WordNoteEditComparison(draft: draft, current: current, fields: fields)
        XCTAssertTrue(refreshed.differences.contains { $0.id == "candidates" })
        try refreshed.apply(to: draft, latest: current, choices: [:])
        XCTAssertEqual(draft.value.count, initial.value.count + 1)
        XCTAssertEqual(draft.value.first { $0.id == added.id }, current.value.first { $0.id == added.id })
        XCTAssertEqual(draft.value.first { $0.id == candidate.id }?.chineseMeaning, "Local meaning")
    }

    func testCandidateLookupRejectsDuplicateForeignAndDeletedIDsWithoutChangingDraft() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let candidate = try Support.candidate("throughput", in: container)
        let other = try Support.candidate("overfitting", in: container)
        let before = try Support.snapshot(container)
        XCTAssertThrowsError(try service.candidateDraftVersion([candidate.id, candidate.id], sourceRecordID: candidate.inputRecordID))
        XCTAssertThrowsError(try service.candidateDraftVersion([other.id], sourceRecordID: candidate.inputRecordID))
        XCTAssertThrowsError(try service.candidateDraftVersion([UUID()], sourceRecordID: candidate.inputRecordID))
        XCTAssertEqual(try Support.snapshot(container), before)
        try service.deleteInputRecord(candidate.inputRecordID, expectedRevision: 0)
        XCTAssertThrowsError(try service.candidateDraftVersion([candidate.id], sourceRecordID: candidate.inputRecordID))
    }

    func testDraftReadingHonorsRestoreGateAndDoesNotReadUncommittedModelsAsStored() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let term = try Support.term("quick", in: container)
        let candidate = try Support.candidate("throughput", in: container)
        let courseID = try XCTUnwrap(term.courseID)
        let read: [() throws -> Void] = [
            { _ = try service.termDraftVersion(term.id) },
            { _ = try service.courseDraftVersion(courseID) },
            { _ = try service.candidateDraftVersion([candidate.id], sourceRecordID: candidate.inputRecordID) },
            { _ = try service.manualSourceDraftVersion(candidate.inputRecordID) }
        ]
        let ticket = try WordNoteWriteGate.beginRestore(container.mainContext)
        for action in read { XCTAssertThrowsError(try action()) { XCTAssertEqual($0 as? WordNoteWriteError, .restoreInProgress) } }
        try WordNoteWriteGate.endRestore(container.mainContext, ticket: ticket)
        term.chineseMeaning = "Direct unsaved edit"
        for action in read { XCTAssertThrowsError(try action()) { XCTAssertEqual($0 as? WordNoteV2ContentError, .unsavedChanges) } }
        XCTAssertEqual(term.chineseMeaning, "Direct unsaved edit")
        XCTAssertTrue(container.mainContext.hasChanges)
        container.mainContext.rollback()
    }

    func testDeletedTermAndCourseCannotBeReloadedForRebase() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let term = try Support.term("quick", in: container)
        let termID = term.id
        try service.deleteTerm(termID, expectedRevision: term.revision)
        XCTAssertThrowsError(try service.termDraftVersion(termID))
        let course = try service.createCourse(courseName: "Disposable synthetic course")
        try service.deleteCourse(course.id, expectedRevision: course.revision)
        XCTAssertThrowsError(try service.courseDraftVersion(course.id))
    }

    func testManualSourceComparisonOnlyRefreshesSourceValues() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let candidate = try Support.candidate("throughput", in: container)
        let initial = try service.manualSourceDraftVersion(candidate.inputRecordID)
        let sourceDraft = WordNoteEditDraft(initial.value, revision: initial.revision)
        var edit = WordNoteV2CandidateEdit(candidate, recordRevision: initial.revision)
        edit.chineseMeaning = "A later candidate edit"
        try service.updateCandidate(edit)
        let current = try service.manualSourceDraftVersion(candidate.inputRecordID)
        let before = try Support.snapshot(container)
        let comparison = try WordNoteEditComparison(draft: sourceDraft, current: current, fields: WordNoteManualSourceValues.comparisonFields())
        try comparison.apply(to: sourceDraft, latest: current, choices: [:])
        XCTAssertEqual(sourceDraft.value, initial.value)
        XCTAssertEqual(sourceDraft.revision, 1)
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testHandledOrAnalyzingManualSourceCannotBeRebased() throws {
        for handled in [true, false] {
            let container = try Support.container()
            let service = try WordNoteV2ContentService(container: container)
            let candidate = try Support.candidate("throughput", in: container)
            let initial = try service.manualSourceDraftVersion(candidate.inputRecordID)
            let draft = WordNoteEditDraft(initial.value, revision: initial.revision)
            if handled { try service.ignoreInputRecord(candidate.inputRecordID, expectedRevision: 0) }
            else { _ = try service.queueAnalysis(candidate.inputRecordID, expectedRevision: 0) }
            let current = try service.manualSourceDraftVersion(candidate.inputRecordID)
            XCTAssertNotNil(current.blockingMessage)
            let before = try Support.snapshot(container)
            let comparison = try WordNoteEditComparison(draft: draft, current: current, fields: WordNoteManualSourceValues.comparisonFields())
            XCTAssertThrowsError(try comparison.apply(to: draft, latest: current, choices: [:]))
            XCTAssertEqual(try Support.snapshot(container), before)
            XCTAssertEqual(draft.revision, 0)
        }
    }

    private func saveTerm(_ value: WordNoteTermEditValues, id: UUID, revision: Int, using service: WordNoteV2ContentService) throws {
        try service.updateTerm(id, expectedRevision: revision, termText: value.termText, termType: value.termType,
                               chineseMeaning: value.chineseMeaning, englishDefinition: value.englishDefinition,
                               aiContextExplanation: value.aiContextExplanation, exampleSentence: value.exampleSentence,
                               contextSentence: value.contextSentence, courseIDs: value.courseIDs, sourceType: value.sourceType,
                               category: value.category, importance: value.importance, masteryLevel: value.masteryLevel)
    }
}
