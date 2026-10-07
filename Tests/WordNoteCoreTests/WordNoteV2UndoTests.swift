import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2UndoTests: XCTestCase {
    private typealias Support = WordNoteV2ServiceTestSupport
    private typealias Term = WordNoteSchemaV2.TermModel
    private typealias Course = WordNoteSchemaV2.CourseModel

    func testUndoTermEditRestoresFieldsAndMembershipsWithIncreasingRevision() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let term = try Support.term("quick", in: container)
        let before = try Support.snapshot(container)
        let oldMeaning = term.chineseMeaning
        try edit(term, using: service)
        XCTAssertEqual(history.title, "Edit Term")
        XCTAssertEqual(history.receipt?.after.values.content.terms.count, 1)
        XCTAssertEqual(history.receipt?.after.values.content.courses.count, 0)
        XCTAssertEqual(history.receipt?.after.values.content.inputRecords.count, 0)
        try history.undo(at: Support.now.addingTimeInterval(1))
        XCTAssertEqual(term.chineseMeaning, oldMeaning)
        XCTAssertEqual(term.revision, 2)
        let after = try Support.snapshot(container)
        XCTAssertEqual(after.courseLinks, before.courseLinks)
        XCTAssertEqual(after.occurrences, before.occurrences)
        XCTAssertEqual(after.lookupEvents, before.lookupEvents)
        XCTAssertEqual(after.content.reviewEvents, before.content.reviewEvents)
        XCTAssertFalse(history.canUndo)
        XCTAssertThrowsError(try history.undo())
    }

    func testUndoCandidateBatchRestoresBothCandidatesAndAdvancesSourceOnce() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let first = try Support.candidate("throughput", in: container)
        let second = try Support.candidate("quick", in: container)
        let record = try Support.record(first.inputRecordID, in: container)
        let old = [first.chineseMeaning, second.chineseMeaning]
        let edits = [first, second].map { candidate in
            var edit = WordNoteV2CandidateEdit(candidate, recordRevision: record.revision)
            edit.chineseMeaning = "Changed meaning"
            return edit
        }
        try service.updateCandidates(edits)
        try history.undo()
        XCTAssertEqual([first.chineseMeaning, second.chineseMeaning], old)
        XCTAssertEqual([first.revision, second.revision], [2, 2])
        XCTAssertEqual(record.revision, 2)
        XCTAssertThrowsError(try service.updateCandidates(edits))
        _ = try Support.snapshot(container)
    }

    func testUndoNewConfirmationRemovesOnlyItsTermAndRelationsAndReturnsCandidateToInbox() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let before = try Support.snapshot(container)
        let candidate = try Support.candidate("throughput", in: container)
        let source = try Support.record(candidate.inputRecordID, in: container)
        let result = try service.confirmCandidate(candidate.id, expectedRevision: 0, expectedRecordRevision: 0,
                                                 operationID: UUID(), target: .createNew, at: Support.now)
        XCTAssertEqual(candidate.savedTermID, result.id)
        try history.undo(at: Support.now.addingTimeInterval(1))
        let after = try Support.snapshot(container)
        XCTAssertEqual(after.content.terms, before.content.terms)
        XCTAssertEqual(after.occurrences, before.occurrences)
        XCTAssertEqual(after.courseLinks, before.courseLinks)
        XCTAssertEqual(candidate.status, .pending)
        XCTAssertNil(candidate.savedTermID)
        XCTAssertNil(candidate.confirmationOperationID)
        XCTAssertEqual(candidate.savedLinkStateRaw, "none")
        XCTAssertEqual(candidate.revision, 2)
        XCTAssertEqual(source.revision, 2)
    }

    func testUndoExistingLinkKeepsOriginalTermAndOtherSources() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let before = try Support.snapshot(container)
        let candidate = try Support.candidate("quick", in: container)
        let term = try Support.term("quick", in: container)
        let meaning = term.chineseMeaning
        _ = try service.confirmCandidate(candidate.id, expectedRevision: 0, expectedRecordRevision: 0,
                                         operationID: UUID(), target: .linkExisting(termID: term.id, expectedRevision: 0))
        try history.undo()
        let after = try Support.snapshot(container)
        XCTAssertEqual(after.content.terms.count, before.content.terms.count)
        XCTAssertEqual(after.occurrences, before.occurrences)
        XCTAssertEqual(after.courseLinks, before.courseLinks)
        XCTAssertEqual(term.chineseMeaning, meaning)
        XCTAssertEqual(candidate.status, .pending)
    }

    func testUndoManualTermPreservesItsInputRecord() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let recordID = try Support.inputID(service.capture(.init(rawText: "A synthetic sentence"), analyze: false))
        let source = try Support.record(recordID, in: container)
        let term = try service.createManualTerm(sourceRecordID: recordID, expectedRecordRevision: source.revision,
                                               termText: "synthetic", chineseMeaning: "合成的", englishDefinition: nil)
        try history.undo()
        XCTAssertFalse(try container.mainContext.fetch(FetchDescriptor<Term>()).contains { $0.id == term.id })
        XCTAssertEqual(try Support.record(recordID, in: container).status, .draft)
        _ = try Support.snapshot(container)
    }

    func testUndoCourseCreationAndEdit() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let created = try service.createCourse(courseName: "Synthetic Course")
        try history.undo()
        XCTAssertFalse(try container.mainContext.fetch(FetchDescriptor<Course>()).contains { $0.id == created.id })
        let course = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<Course>()).first)
        let name = course.courseName
        try service.updateCourse(course.id, expectedRevision: course.revision, courseName: "Edited", courseCode: nil,
                                 instructor: nil, semester: nil, description: nil)
        try history.undo()
        XCTAssertEqual(course.courseName, name)
        XCTAssertEqual(course.revision, 2)
    }

    func testLaterTermEditBlocksUndoWithoutChangingData() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let term = try Support.term("quick", in: container)
        try edit(term, using: WordNoteV2ContentService(container: container, undoHistory: history))
        try edit(term, using: WordNoteV2ContentService(container: container), meaning: "Later edit")
        try assertConflict(history, container: container)
        XCTAssertEqual(term.chineseMeaning, "Later edit")
    }

    func testSubsequentExactLookupBlocksUndo() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let term = try Support.term("quick", in: container)
        try edit(term, using: WordNoteV2ContentService(container: container, undoHistory: history))
        _ = try WordNoteV2ContentService(container: container).capture(.init(rawText: "quick"))
        try assertConflict(history, container: container)
    }

    func testSubsequentReviewBlocksUndo() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let term = try Support.term("quick", in: container)
        try edit(term, using: WordNoteV2ContentService(container: container, undoHistory: history))
        try WordNoteV2ContentService(container: container).recordLegacyFeedback(termID: term.id, expectedRevision: term.revision,
                                                                             mode: .englishToChinese, feedback: .good)
        try assertConflict(history, container: container)
    }

    func testOnlyLastSuccessfulChangeCanBeUndone() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let first = try Support.term("quick", in: container)
        let second = try Support.term("overfitting", in: container)
        let secondOriginal = second.chineseMeaning
        try edit(first, using: service)
        try edit(second, using: service)
        try history.undo()
        XCTAssertEqual(first.chineseMeaning, "Edited")
        XCTAssertEqual(second.chineseMeaning, secondOriginal)
        XCTAssertFalse(history.canUndo)
    }

    func testFailedEditDoesNotReplacePreviousReceipt() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let term = try Support.term("quick", in: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        try edit(term, using: service)
        let receipt = history.receipt
        let before = try Support.snapshot(container)
        let failing = try WordNoteV2ContentService(container: container, undoHistory: history, save: { _ in throw Support.Failure.save })
        XCTAssertThrowsError(try edit(term, using: failing, meaning: "Must roll back"))
        XCTAssertEqual(history.receipt, receipt)
        XCTAssertEqual(try Support.snapshot(container), before)
        try history.undo()
    }

    func testUndoSaveFailureRollsBackAndKeepsReceiptForRetry() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let term = try Support.term("quick", in: container)
        try edit(term, using: WordNoteV2ContentService(container: container, undoHistory: history))
        let receipt = history.receipt
        let before = try Support.snapshot(container)
        let failing = try WordNoteV2ContentService(container: container, undoHistory: history, save: { _ in throw Support.Failure.save })
        XCTAssertThrowsError(try failing.undoLastChange())
        XCTAssertEqual(history.receipt, receipt)
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertFalse(container.mainContext.hasChanges)
        try history.undo()
    }

    func testNewerReceiptCannotBeUndoneByAnOlderWindowAction() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let term = try Support.term("quick", in: container)
        try edit(term, using: service)
        let oldID = try XCTUnwrap(history.operationID)
        try edit(term, using: service, meaning: "Saved during leave confirmation")
        let before = try Support.snapshot(container)
        XCTAssertThrowsError(try history.undo(expectedOperationID: oldID)) { XCTAssertEqual($0 as? WordNoteV2UndoError, .newerChange) }
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertTrue(history.canUndo)
        try history.undo(expectedOperationID: history.operationID)
        XCTAssertEqual(term.chineseMeaning, "Edited")
    }

    func testUnrelatedEditsArePreservedAndDoNotBlockUndo() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let first = try Support.term("quick", in: container)
        let second = try Support.term("overfitting", in: container)
        try edit(first, using: WordNoteV2ContentService(container: container, undoHistory: history))
        try edit(second, using: WordNoteV2ContentService(container: container), meaning: "Unrelated new definition")
        let unrelated = WordNoteSnapshotPayload.Term(second)
        try history.undo()
        XCTAssertEqual(WordNoteSnapshotPayload.Term(second), unrelated)
    }

    func testBacklinkWithoutTermRevisionChangeStillBlocksUndo() throws {
        let container = try Support.container()
        let base = try WordNoteV2ContentService(container: container)
        let first = try Support.candidate("quick", in: container)
        let term = try Support.term("quick", in: container)
        _ = try base.confirmCandidate(first.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: UUID(),
                                      target: .linkExisting(termID: term.id, expectedRevision: term.revision))
        let duplicate = WordNoteSchemaV2.CandidateTermModel(inputRecordID: first.inputRecordID, term: "quick", termType: .word,
                                                           needToLearn: true, importance: .medium, category: .general, chineseMeaning: "快的")
        duplicate.analysisGeneration = first.analysisGeneration
        container.mainContext.insert(duplicate)
        try container.mainContext.save()
        let history = try WordNoteV2UndoHistory(container: container)
        let memberships = Set(try Support.snapshot(container).courseLinks.filter { $0.termID == term.id }.map(\.courseID))
        try edit(term, using: WordNoteV2ContentService(container: container, undoHistory: history), courses: memberships)
        let revision = term.revision
        let source = try Support.record(first.inputRecordID, in: container)
        _ = try base.confirmCandidate(duplicate.id, expectedRevision: 0, expectedRecordRevision: source.revision,
                                      operationID: UUID(), target: .linkExisting(termID: term.id, expectedRevision: revision))
        XCTAssertEqual(term.revision, revision, "This case must be caught by dependency checks, not just revision")
        try assertConflict(history, container: container)
        XCTAssertEqual(duplicate.savedTermID, term.id)
    }

    func testFormerNameNowUsedByAnotherTermBlocksUndoRename() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let term = try Support.term("quick", in: container)
        try edit(term, using: WordNoteV2ContentService(container: container, undoHistory: history), text: "quick rate")
        let service = try WordNoteV2ContentService(container: container)
        let source = try Support.inputID(service.capture(.init(rawText: "Another synthetic sentence"), analyze: false))
        _ = try service.createManualTerm(sourceRecordID: source, expectedRecordRevision: 0,
                                         termText: "quick", chineseMeaning: "快的", englishDefinition: nil)
        try assertConflict(history, container: container)
    }

    func testRemovedMembershipCourseDeletionBlocksUndo() throws {
        let container = try Support.container()
        let base = try WordNoteV2ContentService(container: container)
        let course = try base.createCourse(courseName: "Temporary membership")
        let term = try Support.term("quick", in: container)
        _ = try base.setCourseMembership(termID: term.id, courseID: course.id, included: true, expectedTermRevision: term.revision)
        let history = try WordNoteV2UndoHistory(container: container)
        try edit(term, using: WordNoteV2ContentService(container: container, undoHistory: history))
        let revision = term.revision
        try base.deleteCourse(course.id, expectedRevision: course.revision)
        XCTAssertEqual(term.revision, revision)
        try assertConflict(history, container: container)
    }

    func testReusedRelationIDCannotOverwriteAnotherTermsMembership() throws {
        let container = try Support.container()
        let term = try Support.term("quick", in: container)
        let other = try Support.term("overfitting", in: container)
        let oldLink = try XCTUnwrap(Support.snapshot(container).courseLinks.first { $0.termID == term.id })
        let history = try WordNoteV2UndoHistory(container: container)
        try edit(term, using: WordNoteV2ContentService(container: container, undoHistory: history))
        let course = try WordNoteV2ContentService(container: container).createCourse(courseName: "Another course")
        container.mainContext.insert(WordNoteSchemaV2.TermCourseLinkModel(id: oldLink.id, termID: other.id, courseID: course.id))
        try container.mainContext.save()
        try assertConflict(history, container: container)
    }

    func testNewlyCreatedCourseCannotBeRemovedAfterItIsUsed() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let course = try WordNoteV2ContentService(container: container, undoHistory: history).createCourse(courseName: "Used course")
        _ = try WordNoteV2ContentService(container: container).capture(.init(rawText: "A new draft", courseID: course.id), analyze: false)
        try assertConflict(history, container: container)
    }

    func testDeletedTermIsNotRecreatedByUndo() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let term = try Support.term("quick", in: container)
        try edit(term, using: WordNoteV2ContentService(container: container, undoHistory: history))
        let id = term.id
        try WordNoteV2ContentService(container: container).deleteTerm(id, expectedRevision: term.revision)
        try assertConflict(history, container: container)
        XCTAssertFalse(try container.mainContext.fetch(FetchDescriptor<Term>()).contains { $0.id == id })
    }

    func testConfirmationReplayDoesNotReplaceReceiptOrBecomeAnUndoableDeletion() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let candidate = try Support.candidate("throughput", in: container)
        let operationID = UUID()
        let first = try service.confirmCandidate(candidate.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: operationID, target: .createNew)
        let receipt = history.receipt
        let replay = try service.confirmCandidate(candidate.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: operationID, target: .createNew)
        XCTAssertEqual(first, replay)
        XCTAssertEqual(history.receipt, receipt)
        try history.undo()
        XCTAssertEqual(candidate.status, .pending)
    }

    func testHistoryDoesNotSurviveRestartOrCrossContainers() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        try edit(Support.term("quick", in: container), using: WordNoteV2ContentService(container: container, undoHistory: history))
        let other = try Support.container(populated: false)
        try Support.snapshot(container).populateEmptyStore(other.mainContext)
        XCTAssertThrowsError(try WordNoteV2ContentService(container: other, undoHistory: history)) {
            XCTAssertEqual($0 as? WordNoteV2UndoError, .differentStore)
        }
        let restarted = try WordNoteV2UndoHistory(container: other)
        XCTAssertFalse(restarted.canUndo)
        XCTAssertThrowsError(try restarted.undo()) { XCTAssertEqual($0 as? WordNoteV2UndoError, .unavailable) }
    }

    func testRestoreGateAndUnsavedContextBlockUndoWithoutDiscardingDrafts() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let term = try Support.term("quick", in: container)
        try edit(term, using: WordNoteV2ContentService(container: container, undoHistory: history))
        let receipt = history.receipt
        let ticket = try WordNoteWriteGate.beginRestore(container.mainContext)
        XCTAssertThrowsError(try history.undo()) { XCTAssertEqual($0 as? WordNoteWriteError, .restoreInProgress) }
        try WordNoteWriteGate.endRestore(container.mainContext, ticket: ticket)
        term.chineseMeaning = "Unsaved direct edit"
        XCTAssertThrowsError(try history.undo()) { XCTAssertEqual($0 as? WordNoteV2ContentError, .unsavedChanges) }
        XCTAssertEqual(term.chineseMeaning, "Unsaved direct edit")
        XCTAssertEqual(history.receipt, receipt)
        container.mainContext.rollback()
        try history.undo()
    }

    func testUndoCounterLimitRollsBackWithoutLosingReceipt() throws {
        let container = try Support.container()
        let term = try Support.term("quick", in: container)
        term.revision = 999_999_999
        try container.mainContext.save()
        let history = try WordNoteV2UndoHistory(container: container)
        try edit(term, using: WordNoteV2ContentService(container: container, undoHistory: history))
        let before = try Support.snapshot(container)
        XCTAssertThrowsError(try history.undo()) { XCTAssertEqual($0 as? WordNoteV2ContentError, .counterLimit) }
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertTrue(history.canUndo)
    }

    func testUndoBatchConfirmationIsAllOrNothing() throws {
        let container = try Support.container()
        let first = try Support.candidate("throughput", in: container)
        let second = try Support.candidate("overfitting", in: container)
        second.term = "overfitting risk"
        second.normalizedTerm = TextNormalizer.normalized(second.term)
        try container.mainContext.save()
        let before = try Support.snapshot(container)
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let selected = [first, second].map { WordNoteV2CandidateSelection(id: $0.id, revision: 0, recordID: $0.inputRecordID, recordRevision: 0) }
        _ = try service.confirmNewCandidates(selected)
        try history.undo()
        let after = try Support.snapshot(container)
        XCTAssertEqual(after.content.terms, before.content.terms)
        XCTAssertEqual(after.occurrences, before.occurrences)
        XCTAssertEqual(after.courseLinks, before.courseLinks)
        XCTAssertEqual([first.status, second.status], [.pending, .pending])
    }

    func testNewlyConfirmedTermCannotBeRemovedAfterExactLookup() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let candidate = try Support.candidate("throughput", in: container)
        let result = try WordNoteV2ContentService(container: container, undoHistory: history).confirmCandidate(
            candidate.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: UUID(), target: .createNew
        )
        _ = try WordNoteV2ContentService(container: container).capture(.init(rawText: "throughput"))
        try assertConflict(history, container: container)
        XCTAssertEqual(try Support.term("throughput", in: container).id, result.id)
        XCTAssertEqual(candidate.savedTermID, result.id)
    }

    func testNewlyConfirmedTermCannotBeRemovedAfterReview() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let candidate = try Support.candidate("throughput", in: container)
        let result = try WordNoteV2ContentService(container: container, undoHistory: history).confirmCandidate(
            candidate.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: UUID(), target: .createNew
        )
        try WordNoteV2ContentService(container: container).recordLegacyFeedback(
            termID: result.id, expectedRevision: result.revision, mode: .englishToChinese, feedback: .good
        )
        try assertConflict(history, container: container)
        XCTAssertTrue(try Support.snapshot(container).content.reviewEvents.contains { $0.termID == result.id })
    }

    func testBatchUndoConflictPreservesEveryConfirmedTerm() throws {
        let container = try Support.container()
        let first = try Support.candidate("throughput", in: container)
        let second = try Support.candidate("overfitting", in: container)
        second.term = "overfitting risk"
        second.normalizedTerm = TextNormalizer.normalized(second.term)
        try container.mainContext.save()
        let history = try WordNoteV2UndoHistory(container: container)
        let selections = [first, second].map { WordNoteV2CandidateSelection(id: $0.id, revision: 0, recordID: $0.inputRecordID, recordRevision: 0) }
        _ = try WordNoteV2ContentService(container: container, undoHistory: history).confirmNewCandidates(selections)
        _ = try WordNoteV2ContentService(container: container).capture(.init(rawText: "overfitting risk"))
        try assertConflict(history, container: container)
        XCTAssertEqual(first.savedTermID, try Support.term("throughput", in: container).id)
        XCTAssertEqual(second.savedTermID, try Support.term("overfitting risk", in: container).id)
    }

    func testConfirmationUndoSaveFailureRestoresDeletedEntitiesAndRelations() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let candidate = try Support.candidate("throughput", in: container)
        _ = try WordNoteV2ContentService(container: container, undoHistory: history).confirmCandidate(
            candidate.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: UUID(), target: .createNew
        )
        let before = try Support.snapshot(container)
        let failing = try WordNoteV2ContentService(container: container, undoHistory: history, save: { _ in throw Support.Failure.save })
        XCTAssertThrowsError(try failing.undoLastChange()) { XCTAssertEqual($0 as? Support.Failure, .save) }
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(container.mainContext.hasChanges)
        try history.undo()
        XCTAssertEqual(candidate.status, .pending)
    }

    func testInvalidUndoDatePreservesDataAndReceipt() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        try edit(Support.term("quick", in: container), using: WordNoteV2ContentService(container: container, undoHistory: history))
        let before = try Support.snapshot(container)
        let receipt = history.receipt
        XCTAssertThrowsError(try history.undo(at: Date(timeIntervalSince1970: .infinity))) {
            XCTAssertEqual($0 as? WordNoteV2ContentError, .invalidValue)
        }
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertEqual(history.receipt, receipt)
        try history.undo()
    }

    func testUndoConfirmationPersistsCorrectlyAfterReopeningSQLiteStore() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "wordnote-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "fixture.store")
        let schema = Schema(versionedSchema: WordNoteSchemaV2.self)
        let initial = try Support.snapshot(Support.container())
        let expected: WordNoteSnapshotV2Payload = try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("Undo", schema: schema, url: url)])
            container.mainContext.autosaveEnabled = false
            try initial.populateEmptyStore(container.mainContext)
            let history = try WordNoteV2UndoHistory(container: container)
            let candidate = try Support.candidate("throughput", in: container)
            _ = try WordNoteV2ContentService(container: container, undoHistory: history).confirmCandidate(
                candidate.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: UUID(), target: .createNew
            )
            try history.undo()
            let result = try Support.snapshot(container)
            XCTAssertEqual(result.content.terms, initial.content.terms)
            XCTAssertEqual(result.occurrences, initial.occurrences)
            XCTAssertEqual(result.courseLinks, initial.courseLinks)
            return result
        }
        let reopened = try ModelContainer(for: schema, configurations: [ModelConfiguration("Undo", schema: schema, url: url)])
        XCTAssertEqual(try Support.snapshot(reopened), expected)
        XCTAssertFalse(try WordNoteV2UndoHistory(container: reopened).canUndo)
    }

    private func assertConflict(_ history: WordNoteV2UndoHistory, container: ModelContainer) throws {
        let before = try Support.snapshot(container)
        XCTAssertThrowsError(try history.undo()) { XCTAssertEqual($0 as? WordNoteV2UndoError, .changedSinceSave) }
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertFalse(history.canUndo)
    }

    private func edit(_ term: Term, using service: WordNoteV2ContentService, meaning: String = "Edited", text: String? = nil,
                      courses: Set<UUID> = []) throws {
        try service.updateTerm(term.id, expectedRevision: term.revision, termText: text ?? term.term, termType: term.termType,
                               chineseMeaning: meaning, englishDefinition: term.englishDefinition, aiContextExplanation: term.aiContextExplanation,
                               exampleSentence: term.exampleSentence, contextSentence: term.contextSentence, courseIDs: courses,
                               sourceType: term.sourceType, category: term.category, importance: term.importance, masteryLevel: term.masteryLevel,
                               at: Support.now)
    }
}
