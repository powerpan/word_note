import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3ConfirmationCommitTests: XCTestCase {
    private typealias Support = WordNoteV3ServiceTestSupport
    private typealias Helper = WordNoteV3ServiceTestSupport
    private typealias Term = WordNoteSchemaV3.TermModel

    func testReplayDoesNotSaveAgainAndSurvivesSnapshotRestore() throws {
        let container = try Support.container()
        var saves = 0
        let service = try WordNoteV3ContentService(container: container, beforeSave: { _ in saves += 1 })
        let plan = try Helper.plan(["quick", "throughput"], container: container, service: service)
        let first = try service.commitConfirmationPlan(plan, at: Support.now)
        let after = try Support.contentSnapshot(container)
        let replay = try service.commitConfirmationPlan(plan, at: Support.now.addingTimeInterval(10))
        XCTAssertTrue(replay.wasAlreadyApplied)
        XCTAssertEqual(replay.termIDs, first.termIDs)
        XCTAssertEqual(replay.counts, first.counts)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try Support.contentSnapshot(container), after)
        let restored = try Support.container(populated: false)
        try Support.fullSnapshot(container).populateEmptyStore(restored.mainContext)
        let other = try WordNoteV3ContentService(container: restored)
        XCTAssertTrue(try other.commitConfirmationPlan(plan).wasAlreadyApplied)
        XCTAssertEqual(try Support.contentSnapshot(restored), after)
    }

    func testReplayWithDifferentFieldChoicesIsRejectedWithoutOverwriting() throws {
        let container = try Support.container()
        let candidate = try Support.candidate("quick", in: container)
        candidate.chineseMeaning = "A different meaning"
        try container.mainContext.save()
        let service = try WordNoteV3ContentService(container: container)
        let plan = try Helper.plan(["quick"], container: container, service: service)
        _ = try service.commitConfirmationPlan(plan)
        let before = try Support.contentSnapshot(container)
        var choices = WordNoteV2ConfirmationChoices()
        choices.groups["quick", default: .init()].fieldSources[.chineseMeaning] = candidate.id
        XCTAssertThrowsError(try service.commitConfirmationPlan(plan, choices: choices))
        XCTAssertEqual(try Support.contentSnapshot(container), before)
    }

    func testReplayCannotRecreateDeletedSavedTerm() throws {
        let container = try Support.container()
        let service = try WordNoteV3ContentService(container: container)
        let plan = try Helper.plan(["throughput"], container: container, service: service)
        let result = try service.commitConfirmationPlan(plan)
        try service.deleteTerm(XCTUnwrap(result.termIDs.first), expectedRevision: 0)
        let before = try Support.contentSnapshot(container)
        XCTAssertThrowsError(try service.commitConfirmationPlan(plan))
        XCTAssertEqual(try Support.contentSnapshot(container), before)
    }

    func testAllIgnoredReplayIsExactTerminalConvergenceWithoutTokens() throws {
        let container = try Support.container()
        let service = try WordNoteV3ContentService(container: container)
        let plan = try Helper.plan(["quick", "throughput"], container: container, service: service)
        var choices = WordNoteV2ConfirmationChoices()
        choices.ignoredCandidateIDs = Set(plan.groups.flatMap { $0.candidates.map(\.id) })
        let result = try service.commitConfirmationPlan(plan, choices: choices)
        XCTAssertEqual(result.counts.ignoredCandidates, 2)
        XCTAssertTrue(result.termIDs.isEmpty)
        let after = try Support.contentSnapshot(container)
        XCTAssertTrue(try service.commitConfirmationPlan(plan, choices: choices).wasAlreadyApplied)
        XCTAssertEqual(try Support.contentSnapshot(container), after)
        XCTAssertTrue(after.candidateStates.filter { choices.ignoredCandidateIDs.contains($0.id) }.allSatisfy { $0.confirmationOperationID == nil })
        let candidate = try Support.candidate("quick", in: container)
        candidate.revision += 1
        try container.mainContext.save()
        XCTAssertThrowsError(try service.commitConfirmationPlan(plan, choices: choices))
    }

    func testMixedIgnoredAndSavedReplayDoesNotDuplicateRelations() throws {
        let container = try Support.container()
        let service = try WordNoteV3ContentService(container: container)
        let plan = try Helper.plan(["quick", "throughput", "overfitting"], container: container, service: service)
        var choices = WordNoteV2ConfirmationChoices()
        choices.ignoredCandidateIDs = [try Support.candidate("overfitting", in: container).id]
        _ = try service.commitConfirmationPlan(plan, choices: choices)
        let after = try Support.contentSnapshot(container)
        XCTAssertTrue(try service.commitConfirmationPlan(plan, choices: choices).wasAlreadyApplied)
        XCTAssertEqual(try Support.contentSnapshot(container), after)
        choices.ignoredCandidateIDs = []
        XCTAssertThrowsError(try service.commitConfirmationPlan(plan, choices: choices))
        XCTAssertEqual(try Support.contentSnapshot(container), after)
    }

    func testLaterSourceEditBlocksOldReplayButDoesNotUndoSuccessfulConfirmation() throws {
        let container = try Support.container()
        let service = try WordNoteV3ContentService(container: container)
        let plan = try Helper.plan(["throughput"], container: container, service: service)
        _ = try service.commitConfirmationPlan(plan)
        let candidate = try Support.candidate("throughput", in: container)
        let source = try Support.record(candidate.inputRecordID, in: container)
        source.revision += 1
        source.note = "Later source edit"
        try container.mainContext.save()
        let before = try Support.contentSnapshot(container)
        XCTAssertThrowsError(try service.commitConfirmationPlan(plan))
        XCTAssertEqual(try Support.contentSnapshot(container), before)
        XCTAssertEqual(candidate.status, .saved)
    }

    func testCandidateOrSourceChangedWithoutRevisionStillInvalidatesPreview() throws {
        for changeCandidate in [true, false] {
            let container = try Support.container()
            let service = try WordNoteV3ContentService(container: container)
            let plan = try Helper.plan(["throughput"], container: container, service: service)
            let candidate = try Support.candidate("throughput", in: container)
            if changeCandidate {
                candidate.chineseMeaning = "Changed after preview"
            } else {
                try Support.record(candidate.inputRecordID, in: container).note = "Changed source"
            }
            try container.mainContext.save()
            try assertStale(plan, service: service, container: container)
        }
    }

    func testTargetFieldOrRelationshipChangedInvalidatesPreview() throws {
        for changeRelationship in [true, false] {
            let container = try Support.container()
            let service = try WordNoteV3ContentService(container: container)
            let plan = try Helper.plan(["quick"], container: container, service: service)
            let target = try Support.term("quick", in: container)
            if changeRelationship {
                let links = try container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermCourseLinkModel>())
                container.mainContext.delete(try XCTUnwrap(links.first { $0.termID == target.id }))
            } else {
                target.englishDefinition = "New manual definition"
            }
            try container.mainContext.save()
            try assertStale(plan, service: service, container: container)
        }
    }

    func testNewExactMatchAppearingAfterPreviewBlocksCreation() throws {
        let container = try Support.container()
        let service = try WordNoteV3ContentService(container: container)
        let plan = try Helper.plan(["throughput"], container: container, service: service)
        container.mainContext.insert(Term(term: "THROUGHPUT", termType: .word, chineseMeaning: "Added in another window"))
        try container.mainContext.save()
        try assertStale(plan, service: service, container: container)
        let refreshed = try Helper.plan(["throughput"], container: container, service: service)
        XCTAssertEqual(try refreshed.resolve().counts.newTerms, 0)
        XCTAssertEqual(try refreshed.resolve().counts.linkedCandidates, 1)
        _ = try service.commitConfirmationPlan(refreshed)
    }

    func testRenamedOrDeletedTargetBlocksStalePreview() throws {
        for delete in [true, false] {
            let container = try Support.container()
            let service = try WordNoteV3ContentService(container: container)
            let plan = try Helper.plan(["quick"], container: container, service: service)
            let target = try Support.term("quick", in: container)
            if delete {
                try service.deleteTerm(target.id, expectedRevision: target.revision)
            } else {
                target.term = "renamed"
                target.normalizedTerm = "renamed"
                try container.mainContext.save()
            }
            try assertStale(plan, service: service, container: container)
        }
    }

    func testCourseChangesRequireRefreshedPreview() throws {
        let container = try Support.container()
        let service = try WordNoteV3ContentService(container: container)
        let plan = try Helper.plan(["throughput"], container: container, service: service)
        let source = try Support.record(Support.candidate("throughput", in: container).inputRecordID, in: container)
        let courseID = try XCTUnwrap(source.courseID)
        let course = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.CourseModel>()).first { $0.id == courseID })
        course.courseName = "Renamed course"
        try container.mainContext.save()
        try assertStale(plan, service: service, container: container)
    }

    func testUnrelatedTermEditDoesNotInvalidatePreview() throws {
        let container = try Support.container()
        let service = try WordNoteV3ContentService(container: container)
        let plan = try Helper.plan(["quick", "throughput"], container: container, service: service)
        let unrelated = try Support.term("gradient descent", in: container)
        unrelated.chineseMeaning = "Unrelated edit"
        unrelated.revision += 1
        try container.mainContext.save()
        _ = try service.commitConfirmationPlan(plan)
        XCTAssertEqual(unrelated.chineseMeaning, "Unrelated edit")
        _ = try Support.contentSnapshot(container)
    }

    func testSaveFailureRollsBackMixedNewLinkFillIgnoreAndCanRetrySamePlan() throws {
        let container = try Support.container()
        let history = try WordNoteV3UndoHistory(container: container)
        let service = try WordNoteV3ContentService(container: container, undoHistory: history)
        let candidate = try Support.candidate("quick", in: container)
        candidate.chineseMeaning = "Selected replacement"
        try container.mainContext.save()
        let plan = try Helper.plan(["quick", "throughput", "overfitting"], container: container, service: service)
        var choices = WordNoteV2ConfirmationChoices()
        choices.groups["quick", default: .init()].fieldSources[.chineseMeaning] = candidate.id
        choices.ignoredCandidateIDs = [try Support.candidate("overfitting", in: container).id]
        let before = try Support.contentSnapshot(container)
        var attemptedSaves = 0
        let failing = try WordNoteV3ContentService(container: container, undoHistory: history, beforeSave: { _ in
            attemptedSaves += 1
            throw Support.Failure.save
        })
        XCTAssertThrowsError(try failing.commitConfirmationPlan(plan, choices: choices)) {
            XCTAssertEqual($0 as? Support.Failure, .save)
        }
        XCTAssertEqual(attemptedSaves, 1)
        XCTAssertEqual(try Support.contentSnapshot(container), before)
        XCTAssertFalse(container.mainContext.hasChanges)
        XCTAssertFalse(history.canUndo)
        _ = try service.commitConfirmationPlan(plan, choices: choices)
        XCTAssertTrue(history.canUndo)
        XCTAssertEqual(try Support.term("quick", in: container).chineseMeaning, "Selected replacement")
    }

    func testCounterLimitIsCheckedForWholeBatchBeforeSave() throws {
        let container = try Support.container()
        let candidate = try Support.candidate("throughput", in: container)
        candidate.revision = 1_000_000_000
        try container.mainContext.save()
        var saves = 0
        let service = try WordNoteV3ContentService(container: container, beforeSave: { _ in saves += 1 })
        let plan = try Helper.plan(["quick", "throughput"], container: container, service: service)
        let before = try Support.contentSnapshot(container)
        XCTAssertThrowsError(try service.commitConfirmationPlan(plan)) {
            XCTAssertEqual($0 as? WordNoteV3ContentError, .counterLimit)
        }
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(try Support.contentSnapshot(container), before)
    }

    func testUndoRestoresMixedConfirmationAndReplayCannotReapplyUndonePlan() throws {
        let container = try Support.container()
        let history = try WordNoteV3UndoHistory(container: container)
        let service = try WordNoteV3ContentService(container: container, undoHistory: history)
        let first = try Support.candidate("quick", in: container)
        first.chineseMeaning = "Explicit replacement"
        try container.mainContext.save()
        let before = try Support.contentSnapshot(container)
        let plan = try Helper.plan(["quick", "throughput", "overfitting"], container: container, service: service)
        var choices = WordNoteV2ConfirmationChoices()
        choices.groups["quick", default: .init()].fieldSources[.chineseMeaning] = first.id
        choices.ignoredCandidateIDs = [try Support.candidate("overfitting", in: container).id]
        _ = try service.commitConfirmationPlan(plan, choices: choices)
        let receiptID = history.operationID
        XCTAssertTrue(try service.commitConfirmationPlan(plan, choices: choices).wasAlreadyApplied)
        XCTAssertEqual(history.operationID, receiptID)
        try history.undo()
        let after = try Support.contentSnapshot(container)
        XCTAssertEqual(after.content.terms.count, before.content.terms.count)
        XCTAssertEqual(after.occurrences, before.occurrences)
        XCTAssertEqual(after.courseLinks, before.courseLinks)
        XCTAssertEqual(try Support.term("quick", in: container).chineseMeaning, before.content.terms.first { $0.term == "quick" }?.chineseMeaning)
        XCTAssertTrue(try ["quick", "throughput", "overfitting"].allSatisfy { try Support.candidate($0, in: container).status == .pending })
        XCTAssertThrowsError(try service.commitConfirmationPlan(plan, choices: choices))
        XCTAssertEqual(try Support.contentSnapshot(container), after)
    }

    func testDirtyContextAndRestoreGateBlockPreviewAndCommitWithoutDiscardingEdits() throws {
        let container = try Support.container()
        let service = try WordNoteV3ContentService(container: container)
        let plan = try Helper.plan(["throughput"], container: container, service: service)
        let target = try Support.term("quick", in: container)
        target.chineseMeaning = "Unsaved edit"
        XCTAssertThrowsError(try Helper.plan(["throughput"], container: container, service: service))
        XCTAssertThrowsError(try service.commitConfirmationPlan(plan))
        XCTAssertEqual(target.chineseMeaning, "Unsaved edit")
        XCTAssertTrue(container.mainContext.hasChanges)
        container.mainContext.rollback()
        let ticket = try WordNoteWriteGate.beginRestore(container.mainContext)
        XCTAssertThrowsError(try Helper.plan(["throughput"], container: container, service: service))
        XCTAssertThrowsError(try service.commitConfirmationPlan(plan))
        try WordNoteWriteGate.endRestore(container.mainContext, ticket: ticket)
        _ = try service.commitConfirmationPlan(plan)
    }

    func testQueuedRunningAndStaleGenerationCandidatesCannotEnterPreview() throws {
        for queue in ["queued", "running", "none"] {
            let container = try Support.container()
            let service = try WordNoteV3ContentService(container: container)
            let candidate = try Support.candidate("throughput", in: container)
            let source = try Support.record(candidate.inputRecordID, in: container)
            source.queueStateRaw = queue
            if queue == "none" { source.analysisGeneration += 1 }
            if queue == "running" { source.attemptID = UUID() }
            try container.mainContext.save()
            XCTAssertThrowsError(try Helper.plan(["throughput"], container: container, service: service))
        }
    }

    func testEmptyDuplicateOrStaleSelectionIsRejected() throws {
        let container = try Support.container()
        let service = try WordNoteV3ContentService(container: container)
        let candidate = try Support.candidate("throughput", in: container)
        let selection = try XCTUnwrap(Helper.selections([candidate], in: container).first)
        XCTAssertThrowsError(try service.makeConfirmationPlan([]))
        XCTAssertThrowsError(try service.makeConfirmationPlan([selection, selection]))
        candidate.revision += 1
        try container.mainContext.save()
        XCTAssertThrowsError(try service.makeConfirmationPlan([selection]))
        let fresh = try Helper.selections([candidate], in: container)
        XCTAssertNoThrow(try service.makeConfirmationPlan(fresh))
    }

    func testRefreshPreservesExactSelectionAndReadsNewValuesAndRevisions() throws {
        let container = try Support.container()
        let service = try WordNoteV3ContentService(container: container)
        let plan = try Helper.plan(["throughput"], container: container, service: service)
        let candidate = try Support.candidate("throughput", in: container)
        candidate.chineseMeaning = "Latest meaning"
        candidate.revision += 1
        try Support.record(candidate.inputRecordID, in: container).revision += 1
        try container.mainContext.save()
        let refreshed = try service.refreshConfirmationPlan(plan)
        XCTAssertNotEqual(refreshed.operationID, plan.operationID)
        XCTAssertEqual(refreshed.groups.flatMap(\.candidates).map(\.id), [candidate.id])
        XCTAssertEqual(try refreshed.resolve().groups.first?.content.chineseMeaning, "Latest meaning")
        XCTAssertEqual(refreshed.sourceText(for: candidate.id), plan.sourceText(for: candidate.id))
        XCTAssertNil(refreshed.sourceText(for: UUID()))
        _ = try service.commitConfirmationPlan(refreshed)
    }

    func testRefreshNeverSilentlyDropsHandledOrDeletedCandidate() throws {
        for delete in [true, false] {
            let container = try Support.container()
            let service = try WordNoteV3ContentService(container: container)
            let plan = try Helper.plan(["quick", "throughput"], container: container, service: service)
            let candidate = try Support.candidate("quick", in: container)
            if delete {
                container.mainContext.delete(candidate)
                try container.mainContext.save()
            } else {
                try service.ignoreCandidates(Helper.selections([candidate], in: container))
            }
            let before = try Support.contentSnapshot(container)
            XCTAssertThrowsError(try service.refreshConfirmationPlan(plan))
            XCTAssertEqual(try Support.contentSnapshot(container), before)
        }
    }

    private func assertStale(
        _ plan: WordNoteV2ConfirmationPlan, service: WordNoteV3ContentService, container: ModelContainer
    ) throws {
        let before = try Support.contentSnapshot(container)
        XCTAssertThrowsError(try service.commitConfirmationPlan(plan)) {
            XCTAssertEqual($0 as? WordNoteV2ConfirmationPlanError, .stalePlan)
        }
        XCTAssertEqual(try Support.contentSnapshot(container), before)
    }
}
