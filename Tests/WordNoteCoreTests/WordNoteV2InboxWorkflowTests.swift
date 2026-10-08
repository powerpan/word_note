import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2InboxWorkflowTests: XCTestCase {
    private typealias Support = WordNoteV2ServiceTestSupport
    private typealias Record = WordNoteSchemaV2.InputRecordModel
    private typealias Candidate = WordNoteSchemaV2.CandidateTermModel

    func testUndoPartialIgnoreRestoresCandidateWithoutChangingOtherContent() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let before = try Support.snapshot(container)
        let candidate = try Support.candidate("throughput", in: container)
        let record = try Support.record(candidate.inputRecordID, in: container)
        try service.ignoreCandidates([selection(candidate, record: record)], at: Support.now)
        XCTAssertEqual(history.title, "Ignore Candidates")
        XCTAssertEqual(candidate.status, .ignored)
        XCTAssertEqual(record.status, .analyzed)
        try history.undo(at: Support.now.addingTimeInterval(1))
        XCTAssertEqual(candidate.status, .pending)
        XCTAssertEqual(candidate.revision, 2)
        XCTAssertEqual(record.revision, 2)
        let after = try Support.snapshot(container)
        XCTAssertEqual(after.content.terms, before.content.terms)
        XCTAssertEqual(after.occurrences, before.occurrences)
        XCTAssertEqual(after.courseLinks, before.courseLinks)
        XCTAssertEqual(after.lookupEvents, before.lookupEvents)
        XCTAssertEqual(after.content.reviewEvents, before.content.reviewEvents)
    }

    func testIgnoreAllMovesToHandledAndUndoReopensWithoutStealingNextFocus() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let target = try Support.candidate("quick", in: container)
        let record = try Support.record(target.inputRecordID, in: container)
        var focus = InboxSelection()
        var result = try browse(container)
        focus.reconcile(active: result.active.map(\.id), handled: [], confirmable: result.confirmableIDs)
        focus.focusedID = record.id
        let item = try XCTUnwrap(result.active.first { $0.id == record.id })
        try service.ignoreCandidates(item.selections, at: Support.now)
        result = try browse(container)
        XCTAssertEqual(record.status, .completed)
        XCTAssertTrue(result.handled.contains { $0.id == record.id })
        focus.reconcile(active: result.active.map(\.id), handled: result.handled.map(\.id), confirmable: result.confirmableIDs)
        let next = try XCTUnwrap(focus.focusedID)
        XCTAssertNotEqual(next, record.id)
        try history.undo(at: Support.now.addingTimeInterval(1))
        result = try browse(container)
        focus.reconcile(active: result.active.map(\.id), handled: [], confirmable: result.confirmableIDs)
        XCTAssertEqual(focus.focusedID, next)
        XCTAssertTrue(result.confirmableIDs.contains(record.id))
        XCTAssertEqual(target.status, .pending)
    }

    func testUndoIgnoredRecordPreservesAlreadySavedCandidateAndTermLinks() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let saved = try Support.candidate("throughput", in: container)
        let record = try Support.record(saved.inputRecordID, in: container)
        _ = try service.confirmNewCandidates([selection(saved, record: record)], at: Support.now)
        let before = try Support.snapshot(container)
        try service.ignoreInputRecord(record.id, expectedRevision: record.revision, at: Support.now)
        XCTAssertEqual(history.title, "Ignore Input Record")
        XCTAssertEqual(record.status, .ignored)
        try history.undo(at: Support.now.addingTimeInterval(1))
        let after = try Support.snapshot(container)
        XCTAssertEqual(record.status, .analyzed)
        XCTAssertEqual(saved.status, .saved)
        XCTAssertEqual(after.candidateStates.first { $0.id == saved.id }, before.candidateStates.first { $0.id == saved.id })
        XCTAssertEqual(after.content.terms, before.content.terms)
        XCTAssertEqual(after.occurrences, before.occurrences)
        XCTAssertEqual(after.courseLinks, before.courseLinks)
        XCTAssertEqual(try Support.candidate("quick", in: container).status, .pending)
    }

    func testUndoRecordIgnoreRestoresFailureOrCancellationAndProviderDeadline() throws {
        for cancelled in [false, true] {
            let container = try Support.container(populated: false)
            let history = try WordNoteV2UndoHistory(container: container)
            let service = try WordNoteV2ContentService(container: container, undoHistory: history)
            let id = try Support.inputID(service.capture(.init(rawText: "Synthetic query"), at: Support.now))
            let attempt = try service.beginAnalysis(id, expectedRevision: 0, at: Support.now)
            let deadline = Support.now.addingTimeInterval(cancelled ? 30 : 120)
            try service.failAnalysis(attempt, error: AIAnalysisRetryAfterError(failure: .rateLimited, notBefore: deadline), at: Support.now)
            let record = try Support.record(id, in: container)
            if cancelled { try service.cancelAnalysis(id, expectedRevision: record.revision, at: Support.now) }
            let state = WordNoteSnapshotV2Payload.RecordState(record)
            let error = record.aiErrorSummary
            try service.ignoreInputRecord(id, expectedRevision: record.revision, at: Support.now)
            XCTAssertEqual(record.queueStateRaw, "none")
            try history.undo(at: Support.now.addingTimeInterval(1))
            XCTAssertEqual(record.status, .draft)
            XCTAssertEqual(record.queueStateRaw, state.queueStateRaw)
            XCTAssertEqual(record.nextAttemptAt, deadline)
            XCTAssertEqual(record.aiErrorSummary, error)
            XCTAssertEqual(record.analysisGeneration, state.analysisGeneration)
            XCTAssertEqual(record.autoRetryCount, state.autoRetryCount)
            XCTAssertEqual(record.revision, state.revision + 2)
            XCTAssertEqual(try service.analysisJobs().first?.state.rawValue, state.queueStateRaw)
            XCTAssertThrowsError(try service.queueAnalysis(id, expectedRevision: record.revision, at: Support.now.addingTimeInterval(2)))
            _ = try Support.snapshot(container)
        }
    }

    func testFailedIgnoreRollsBackAndDoesNotReplacePreviousReceipt() throws {
        for wholeRecord in [false, true] {
            let container = try Support.container()
            let history = try WordNoteV2UndoHistory(container: container)
            let service = try WordNoteV2ContentService(container: container, undoHistory: history)
            _ = try service.createCourse(courseName: "Keep prior undo", at: Support.now)
            let receipt = history.receipt
            let before = try Support.snapshot(container)
            let candidate = try Support.candidate("throughput", in: container)
            let record = try Support.record(candidate.inputRecordID, in: container)
            let failing = try WordNoteV2ContentService(container: container, undoHistory: history, save: { _ in throw Support.Failure.save })
            if wholeRecord {
                XCTAssertThrowsError(try failing.ignoreInputRecord(record.id, expectedRevision: record.revision))
            } else {
                XCTAssertThrowsError(try failing.ignoreCandidates([selection(candidate, record: record)]))
            }
            XCTAssertEqual(try Support.snapshot(container), before)
            XCTAssertEqual(history.receipt, receipt)
            XCTAssertFalse(container.mainContext.hasChanges)
            try history.undo()
        }
    }

    func testStaleSelectionRejectsWholeBatchAndEmptyIgnoreKeepsUndo() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        _ = try service.createCourse(courseName: "Prior change")
        let receipt = history.receipt
        let before = try Support.snapshot(container)
        let candidate = try Support.candidate("throughput", in: container)
        let record = try Support.record(candidate.inputRecordID, in: container)
        let values = [selection(candidate, record: record), WordNoteV2CandidateSelection(id: UUID(), revision: 0, recordID: record.id, recordRevision: record.revision)]
        XCTAssertThrowsError(try service.ignoreCandidates(values))
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertEqual(history.receipt, receipt)
        try service.ignoreCandidates([])
        XCTAssertEqual(history.receipt, receipt)
    }

    func testLaterReanalysisBlocksUndoOfCandidateIgnore() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let candidate = try Support.candidate("throughput", in: container)
        let record = try Support.record(candidate.inputRecordID, in: container)
        try service.ignoreCandidates([selection(candidate, record: record)], at: Support.now)
        try service.queueAnalysis(record.id, expectedRevision: record.revision, at: Support.now)
        let before = try Support.snapshot(container)
        XCTAssertThrowsError(try history.undo()) { XCTAssertEqual($0 as? WordNoteV2UndoError, .changedSinceSave) }
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertFalse(history.canUndo)
    }

    func testChangedUnselectedCandidateBlocksUndoOfWholeRecordIgnore() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let saved = try Support.candidate("throughput", in: container)
        let record = try Support.record(saved.inputRecordID, in: container)
        _ = try service.confirmNewCandidates([selection(saved, record: record)])
        try service.ignoreInputRecord(record.id, expectedRevision: record.revision)
        saved.revision += 1
        try container.mainContext.save()
        let before = try Support.snapshot(container)
        XCTAssertThrowsError(try history.undo()) { XCTAssertEqual($0 as? WordNoteV2UndoError, .changedSinceSave) }
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testQueueRestoreAndDirtyGuardsApplyToUndoableIgnorePaths() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let candidate = try Support.candidate("throughput", in: container)
        let record = try Support.record(candidate.inputRecordID, in: container)
        let ticket = try WordNoteWriteGate.beginRestore(container.mainContext)
        XCTAssertThrowsError(try service.ignoreInputRecord(record.id, expectedRevision: record.revision))
        XCTAssertThrowsError(try service.ignoreCandidates([selection(candidate, record: record)]))
        try WordNoteWriteGate.endRestore(container.mainContext, ticket: ticket)
        candidate.chineseMeaning = "Unsaved external change"
        XCTAssertThrowsError(try service.ignoreCandidates([selection(candidate, record: record)])) {
            XCTAssertEqual($0 as? WordNoteV2ContentError, .unsavedChanges)
        }
        XCTAssertEqual(candidate.chineseMeaning, "Unsaved external change")
        container.mainContext.rollback()
        for queueState in ["queued", "running"] {
            record.queueStateRaw = queueState
            record.attemptID = queueState == "running" ? UUID() : nil
            try container.mainContext.save()
            let before = try Support.snapshot(container)
            XCTAssertThrowsError(try service.ignoreInputRecord(record.id, expectedRevision: record.revision))
            XCTAssertThrowsError(try service.ignoreCandidates([selection(candidate, record: record)]))
            XCTAssertEqual(try Support.snapshot(container), before)
        }
        XCTAssertFalse(history.canUndo)
    }

    func testPartialConfirmationStaysCurrentAndWholeConfirmationAdvances() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let quick = try Support.candidate("quick", in: container), throughput = try Support.candidate("throughput", in: container)
        let record = try Support.record(quick.inputRecordID, in: container)
        var focus = InboxSelection()
        var result = try browse(container)
        focus.reconcile(active: result.active.map(\.id), handled: [], confirmable: result.confirmableIDs)
        focus.focusedID = record.id
        for candidate in [quick, throughput] {
            let plan = try service.makeConfirmationPlan([selection(candidate, record: record)])
            _ = try service.commitConfirmationPlan(plan, at: Support.now)
            result = try browse(container)
            focus.reconcile(active: result.active.map(\.id), handled: [], confirmable: result.confirmableIDs)
            if candidate.id == quick.id {
                XCTAssertEqual(focus.focusedID, record.id)
                XCTAssertEqual(result.selectedCounts([record.id]).candidates, 1)
            } else {
                XCTAssertNotEqual(focus.focusedID, record.id)
                XCTAssertTrue(result.handled.contains { $0.id == record.id })
            }
        }
        let next = focus.focusedID
        try history.undo()
        result = try browse(container)
        focus.reconcile(active: result.active.map(\.id), handled: [], confirmable: result.confirmableIDs)
        XCTAssertEqual(focus.focusedID, next)
        XCTAssertEqual(result.selectedCounts([record.id]).candidates, 1)
    }

    func testFailedReanalysisCandidatesCanBePreviewedAndConfirmedWithoutClearingTaskHistory() throws {
        let container = try Support.container(populated: false)
        let service = try WordNoteV2ContentService(container: container)
        let id = try Support.inputID(service.capture(.init(rawText: "Synthetic query"), at: Support.now))
        let attempt = try service.beginAnalysis(id, expectedRevision: 0, at: Support.now)
        try service.completeAnalysis(attempt, result: AnalysisTestValues.result(), at: Support.now)
        let record = try Support.record(id, in: container)
        try service.queueAnalysis(id, expectedRevision: record.revision, at: Support.now)
        let retry = try service.beginAnalysis(id, expectedRevision: record.revision, at: Support.now)
        try service.failAnalysis(retry, error: AIAnalysisError.invalidResponse, at: Support.now)
        let item = try XCTUnwrap(browse(container).active.first)
        XCTAssertTrue(item.canConfirm)
        XCTAssertTrue(item.isFailed)
        _ = try service.commitConfirmationPlan(service.makeConfirmationPlan(item.selections), at: Support.now)
        XCTAssertEqual(try browse(container).handled.map(\.id), [id])
        XCTAssertEqual(try service.analysisJobs().first?.state, .failed)
        XCTAssertEqual(try Support.snapshot(container).content.terms.count, 1)
    }

    private func selection(_ candidate: Candidate, record: Record) -> WordNoteV2CandidateSelection {
        .init(id: candidate.id, revision: candidate.revision, recordID: record.id, recordRevision: record.revision)
    }

    private func browse(_ container: ModelContainer) throws -> InboxBrowseResult {
        let candidates = try container.mainContext.fetch(FetchDescriptor<Candidate>())
        let records = try container.mainContext.fetch(FetchDescriptor<Record>())
        return InboxBrowseIndex(items: records.map { .init(record: $0, candidates: candidates) }).matching(.init())
    }
}
