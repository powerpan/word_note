import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2OrganizationCommitTests: XCTestCase {
    private typealias Fixture = OrganizationTestFixture
    private typealias Support = WordNoteV2ServiceTestSupport

    func testChangedFieldsEvenWithoutRevisionInvalidateEntirePlan() throws {
        let fixture = try Fixture()
        let plan = try fixture.plan()
        fixture.second.chineseMeaning = "A later manual edit"
        try fixture.container.mainContext.save()
        try assertStale(plan, fixture: fixture)
        XCTAssertEqual(fixture.second.chineseMeaning, "A later manual edit")
    }

    func testRevisionOrCounterSemanticsChangesInvalidatePlan() throws {
        for revision in [true, false] {
            let fixture = try Fixture()
            let plan = try fixture.plan()
            if revision { fixture.second.revision += 1 }
            else { fixture.second.counterSemanticsVersionRaw = "eventBasedV2" }
            try fixture.container.mainContext.save()
            // Counter semantics are checked independently of the editable content snapshot.
            XCTAssertThrowsError(try fixture.service.commitOrganizationPlan(plan)) {
                XCTAssertEqual($0 as? WordNoteV2OrganizationError, .stalePlan)
            }
            XCTAssertFalse(fixture.container.mainContext.hasChanges)
        }
    }

    func testMembershipChangesEvenWithoutTermRevisionInvalidatePlan() throws {
        let fixture = try Fixture()
        let plan = try fixture.plan()
        let link = try XCTUnwrap(fixture.container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV2.TermCourseLinkModel>()).first)
        fixture.container.mainContext.delete(link)
        try fixture.container.mainContext.save()
        try assertStale(plan, fixture: fixture)
    }

    func testCourseRenameRevisionOrDeletionInvalidatesPreview() throws {
        for mode in 0..<3 {
            let fixture = try Fixture()
            let plan = try fixture.plan()
            switch mode {
            case 0: fixture.destination.courseName = "Renamed after preview"
            case 1: fixture.destination.revision += 1
            default: fixture.container.mainContext.delete(fixture.destination)
            }
            try fixture.container.mainContext.save()
            try assertStale(plan, fixture: fixture)
        }
    }

    func testDeletedSelectedTermRejectsWholePlanInsteadOfShrinkingSelection() throws {
        let fixture = try Fixture()
        let plan = try fixture.plan()
        try fixture.service.deleteTerm(fixture.second.id, expectedRevision: 0)
        try assertStale(plan, fixture: fixture)
    }

    func testUnrelatedTermEditsDoNotInvalidatePlan() throws {
        let fixture = try Fixture()
        let plan = try fixture.plan()
        let other = WordNoteSchemaV2.TermModel(term: "unrelated", termType: .word, chineseMeaning: "Unrelated edit")
        fixture.container.mainContext.insert(other)
        try fixture.container.mainContext.save()
        _ = try fixture.service.commitOrganizationPlan(plan)
        XCTAssertEqual(other.chineseMeaning, "Unrelated edit")
        XCTAssertEqual(other.revision, 0)
    }

    func testSaveFailureRollsBackEverythingKeepsPriorUndoAndAllowsRetry() throws {
        let fixture = try Fixture()
        var initial = WordNoteV2OrganizationChanges()
        initial.tagsToAdd = ["prior"]
        _ = try fixture.service.commitOrganizationPlan(fixture.service.makeOrganizationPlan(termIDs: [fixture.first.id], changes: initial))
        let receipt = fixture.history.operationID
        let plan = try fixture.plan()
        let before = try fixture.snapshot()
        var saves = 0
        let failing = try WordNoteV2ContentService(container: fixture.container, undoHistory: fixture.history, save: { _ in
            saves += 1
            throw Support.Failure.save
        })
        XCTAssertThrowsError(try failing.commitOrganizationPlan(plan)) { XCTAssertEqual($0 as? Support.Failure, .save) }
        XCTAssertEqual(saves, 1)
        XCTAssertFalse(fixture.container.mainContext.hasChanges)
        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertEqual(fixture.history.operationID, receipt)
        _ = try fixture.service.commitOrganizationPlan(plan)
        XCTAssertNotEqual(fixture.history.operationID, receipt)
    }

    func testCounterLimitIsValidatedForWholeBatchBeforeAnySave() throws {
        let fixture = try Fixture()
        fixture.second.revision = 1_000_000_000
        try fixture.container.mainContext.save()
        let plan = try fixture.plan()
        let before = try fixture.snapshot()
        var saves = 0
        let service = try WordNoteV2ContentService(container: fixture.container, save: { saves += 1; try $0.save() })
        XCTAssertThrowsError(try service.commitOrganizationPlan(plan)) { XCTAssertEqual($0 as? WordNoteV2ContentError, .counterLimit) }
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testInvalidDateDoesNotWrite() throws {
        let fixture = try Fixture()
        let plan = try fixture.plan()
        let before = try fixture.snapshot()
        XCTAssertThrowsError(try fixture.service.commitOrganizationPlan(plan, at: Date(timeIntervalSince1970: .infinity)))
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testDirtyContextAndRestoreGateBlockPreviewAndCommitWithoutDiscardingDraft() throws {
        let fixture = try Fixture()
        let plan = try fixture.plan()
        let ticket = try WordNoteWriteGate.beginRestore(fixture.container.mainContext)
        XCTAssertThrowsError(try fixture.plan())
        XCTAssertThrowsError(try fixture.service.commitOrganizationPlan(plan))
        try WordNoteWriteGate.endRestore(fixture.container.mainContext, ticket: ticket)
        fixture.first.englishDefinition = "Unsaved external edit"
        XCTAssertThrowsError(try fixture.plan()) { XCTAssertEqual($0 as? WordNoteV2ContentError, .unsavedChanges) }
        XCTAssertThrowsError(try fixture.service.commitOrganizationPlan(plan)) { XCTAssertEqual($0 as? WordNoteV2ContentError, .unsavedChanges) }
        XCTAssertEqual(fixture.first.englishDefinition, "Unsaved external edit")
        XCTAssertTrue(fixture.container.mainContext.hasChanges)
        fixture.container.mainContext.rollback()
    }

    func testOldCommittedPlanCannotBeAppliedTwice() throws {
        let fixture = try Fixture()
        let plan = try fixture.plan()
        _ = try fixture.service.commitOrganizationPlan(plan)
        try assertStale(plan, fixture: fixture)
    }

    func testUndoRestoresExactMembershipIdentitiesAndTagArrays() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()
        _ = try fixture.service.commitOrganizationPlan(fixture.plan(), at: Support.now)
        XCTAssertEqual(fixture.history.title, "Organize Vocabulary")
        try fixture.history.undo(at: Support.now.addingTimeInterval(1))
        let after = try fixture.snapshot()
        XCTAssertEqual(after.courseLinks, before.courseLinks)
        for original in before.content.terms {
            var expected = original
            expected.updatedAt = Support.now.addingTimeInterval(1)
            XCTAssertEqual(after.content.terms.first { $0.id == original.id }, expected)
            XCTAssertEqual(after.termStates.first { $0.id == original.id }?.revision, 2)
        }
        XCTAssertFalse(fixture.history.canUndo)
    }

    func testLaterTermEditBlocksUndoWithoutOverwritingNewContent() throws {
        let fixture = try Fixture()
        _ = try fixture.service.commitOrganizationPlan(fixture.plan())
        fixture.first.exampleSentence = "A later example"
        fixture.first.revision += 1
        try fixture.container.mainContext.save()
        let before = try fixture.snapshot()
        XCTAssertThrowsError(try fixture.history.undo()) { XCTAssertEqual($0 as? WordNoteV2UndoError, .changedSinceSave) }
        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertFalse(fixture.history.canUndo)
    }

    private func assertStale(_ plan: WordNoteV2OrganizationPlan, fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try fixture.snapshot()
        let receipt = fixture.history.operationID
        XCTAssertThrowsError(try fixture.service.commitOrganizationPlan(plan), file: file, line: line) {
            XCTAssertEqual($0 as? WordNoteV2OrganizationError, .stalePlan, file: file, line: line)
        }
        XCTAssertEqual(try fixture.snapshot(), before, file: file, line: line)
        XCTAssertEqual(fixture.history.operationID, receipt, file: file, line: line)
    }
}
