import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2OrganizationTests: XCTestCase {
    private typealias Fixture = OrganizationTestFixture
    private typealias Support = WordNoteV2ServiceTestSupport

    func testPreviewIsReadOnlyAndCountsAssignmentsRatherThanRawLegacyDuplicates() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()
        let plan = try fixture.plan()
        XCTAssertEqual(plan.counts, .init(selectedTerms: 2, changedTerms: 2, coursesAdded: 2, coursesRemoved: 2, tagsAdded: 2, tagsRemoved: 1))
        XCTAssertEqual(plan.entries.first { $0.id == fixture.first.id }?.tagsAfter, ["Keep", "New Tag"])
        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertFalse(fixture.container.mainContext.hasChanges)
        XCTAssertFalse(fixture.history.canUndo)
    }

    func testCommitSavesOnceAndOnlyChangesTagsMembershipsRevisionAndUpdateTime() throws {
        let fixture = try Fixture()
        _ = try fixture.service.capture(.init(rawText: "alpha", capturedVia: .mainQuickAdd), at: Support.now)
        let before = try fixture.snapshot()
        var saves = 0
        let service = try WordNoteV2ContentService(container: fixture.container, save: { saves += 1; try $0.save() })
        let plan = try fixture.plan(service: service)
        XCTAssertEqual(try service.commitOrganizationPlan(plan, at: Support.now), plan.counts)
        XCTAssertEqual(saves, 1)
        let after = try fixture.snapshot()
        XCTAssertEqual(after.occurrences, before.occurrences)
        XCTAssertEqual(after.lookupEvents, before.lookupEvents)
        XCTAssertEqual(after.content.reviewEvents, before.content.reviewEvents)
        XCTAssertEqual(after.content.candidates, before.content.candidates)
        XCTAssertEqual(after.content.inputRecords, before.content.inputRecords)
        XCTAssertEqual(after.content.courses, before.content.courses)
        for entry in plan.entries {
            var expected = entry.before
            expected.tags = entry.tagsAfter
            expected.updatedAt = Support.now
            XCTAssertEqual(after.content.terms.first { $0.id == entry.id }, expected)
            XCTAssertEqual(after.termStates.first { $0.id == entry.id }?.revision, entry.state.revision + 1)
            XCTAssertEqual(Set(after.courseLinks.filter { $0.termID == entry.id }.map(\.courseID)), [fixture.destination.id])
        }
        XCTAssertEqual(fixture.first.courseID, fixture.origin.id)
    }

    func testCourseOnlyChangePreservesOriginalTagArrayExactly() throws {
        let fixture = try Fixture()
        let before = fixture.first.tags
        var changes = WordNoteV2OrganizationChanges()
        changes.coursesToAdd = [fixture.destination.id]
        let plan = try fixture.service.makeOrganizationPlan(termIDs: [fixture.first.id], changes: changes)
        _ = try fixture.service.commitOrganizationPlan(plan)
        XCTAssertEqual(fixture.first.tags, before)
        XCTAssertEqual(fixture.first.courseID, fixture.origin.id)
    }

    func testTagAddDeduplicatesNormalizedKeysWithoutRewritingExistingSpelling() throws {
        let fixture = try Fixture()
        var changes = WordNoteV2OrganizationChanges()
        changes.tagsToAdd = [" CORE ", "New   Tag", "new tag", " AI, ML "]
        let plan = try fixture.service.makeOrganizationPlan(termIDs: [fixture.first.id], changes: changes)
        XCTAssertEqual(plan.counts.tagsAdded, 2)
        _ = try fixture.service.commitOrganizationPlan(plan)
        XCTAssertEqual(fixture.first.tags, [" Core ", "core", "Keep", "New Tag", "AI, ML"])
    }

    func testRemovingTagRemovesAllNormalizedVariantsButCountsOneAssignment() throws {
        let fixture = try Fixture()
        var changes = WordNoteV2OrganizationChanges()
        changes.tagsToRemove = ["CORE", " core ", "nonexistent"]
        let plan = try fixture.service.makeOrganizationPlan(termIDs: [fixture.first.id], changes: changes)
        XCTAssertEqual(plan.counts.tagsRemoved, 1)
        _ = try fixture.service.commitOrganizationPlan(plan)
        XCTAssertEqual(fixture.first.tags, ["Keep"])
    }

    func testLongLegacyTagCanBeRemovedAlthoughNewTagsHaveEightyCharacterLimit() throws {
        let fixture = try Fixture()
        let old = String(repeating: "x", count: 81)
        fixture.first.tags.append(old)
        try fixture.container.mainContext.save()
        var changes = WordNoteV2OrganizationChanges()
        changes.tagsToRemove = [old]
        let plan = try fixture.service.makeOrganizationPlan(termIDs: [fixture.first.id], changes: changes)
        _ = try fixture.service.commitOrganizationPlan(plan)
        XCTAssertFalse(fixture.first.tags.contains(old))
        changes = .init(); changes.tagsToAdd = [old]
        XCTAssertThrowsError(try fixture.service.makeOrganizationPlan(termIDs: [fixture.first.id], changes: changes))
    }

    func testEmptyMissingAndConflictingRequestsDoNotChangeAnything() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()
        XCTAssertThrowsError(try fixture.service.makeOrganizationPlan(termIDs: [], changes: fixture.changes)) {
            XCTAssertEqual($0 as? WordNoteV2OrganizationError, .emptySelection)
        }
        XCTAssertThrowsError(try fixture.service.makeOrganizationPlan(termIDs: fixture.ids, changes: .init())) {
            XCTAssertEqual($0 as? WordNoteV2OrganizationError, .emptyChanges)
        }
        XCTAssertThrowsError(try fixture.service.makeOrganizationPlan(termIDs: fixture.ids.union([UUID()]), changes: fixture.changes))
        var conflict = fixture.changes
        conflict.coursesToRemove.insert(fixture.destination.id)
        XCTAssertThrowsError(try fixture.service.makeOrganizationPlan(termIDs: fixture.ids, changes: conflict)) {
            XCTAssertEqual($0 as? WordNoteV2OrganizationError, .conflictingChanges)
        }
        conflict = fixture.changes; conflict.tagsToRemove.append("NEW   TAG")
        XCTAssertThrowsError(try fixture.service.makeOrganizationPlan(termIDs: fixture.ids, changes: conflict)) {
            XCTAssertEqual($0 as? WordNoteV2OrganizationError, .conflictingChanges)
        }
        conflict = fixture.changes; conflict.coursesToAdd.insert(UUID())
        XCTAssertThrowsError(try fixture.service.makeOrganizationPlan(termIDs: fixture.ids, changes: conflict))
        conflict = fixture.changes; conflict.tagsToRemove = [" \n "]
        XCTAssertThrowsError(try fixture.service.makeOrganizationPlan(termIDs: fixture.ids, changes: conflict))
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testTagArrayLimitRejectsOverflowAndAllowsRemovalBeforeAddition() throws {
        let fixture = try Fixture()
        fixture.first.tags = (0..<10_000).map { "tag-\($0)" }
        try fixture.container.mainContext.save()
        var changes = WordNoteV2OrganizationChanges()
        changes.tagsToAdd = ["new"]
        XCTAssertThrowsError(try fixture.service.makeOrganizationPlan(termIDs: [fixture.first.id], changes: changes)) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .sizeLimit)
        }
        changes.tagsToRemove = ["tag-0"]
        let plan = try fixture.service.makeOrganizationPlan(termIDs: [fixture.first.id], changes: changes)
        XCTAssertEqual(plan.entries[0].tagsAfter.count, 10_000)
        XCTAssertFalse(fixture.container.mainContext.hasChanges)
    }

    func testFreshEquivalentPlanIsNoOpAndKeepsPreviousUndoReceipt() throws {
        let fixture = try Fixture()
        _ = try fixture.service.commitOrganizationPlan(fixture.plan(), at: Support.now)
        let receipt = fixture.history.operationID
        let before = try fixture.snapshot()
        var saves = 0
        let service = try WordNoteV2ContentService(container: fixture.container, undoHistory: fixture.history,
                                                  save: { saves += 1; try $0.save() })
        let sameRequest = try fixture.plan(service: service)
        XCTAssertEqual(sameRequest.counts.changedTerms, 0)
        XCTAssertEqual(try service.commitOrganizationPlan(sameRequest).changedTerms, 0)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(fixture.history.operationID, receipt)
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testMixedNoOpAndChangeOnlyTouchesChangedTermIncludingUndo() throws {
        let fixture = try Fixture()
        var changes = WordNoteV2OrganizationChanges()
        changes.tagsToAdd = ["Core"]
        let untouched = WordNoteSnapshotPayload.Term(fixture.first)
        let plan = try fixture.service.makeOrganizationPlan(termIDs: fixture.ids, changes: changes)
        XCTAssertEqual(plan.counts.changedTerms, 1)
        _ = try fixture.service.commitOrganizationPlan(plan, at: Support.now)
        XCTAssertEqual(fixture.first.revision, 0)
        XCTAssertEqual(fixture.second.revision, 1)
        try fixture.history.undo(at: Support.now.addingTimeInterval(1))
        XCTAssertEqual(WordNoteSnapshotPayload.Term(fixture.first), untouched)
        XCTAssertEqual(fixture.first.revision, 0)
        XCTAssertEqual(fixture.second.revision, 2)
        XCTAssertEqual(fixture.second.tags, ["Keep"])
    }
}

@MainActor
struct OrganizationTestFixture {
    let container: ModelContainer
    let history: WordNoteV2UndoHistory
    let service: WordNoteV2ContentService
    let first: WordNoteSchemaV2.TermModel
    let second: WordNoteSchemaV2.TermModel
    let origin: WordNoteSchemaV2.CourseModel
    let destination: WordNoteSchemaV2.CourseModel
    var ids: Set<UUID> { [first.id, second.id] }
    var changes: WordNoteV2OrganizationChanges {
        var value = WordNoteV2OrganizationChanges()
        value.coursesToAdd = [destination.id]
        value.coursesToRemove = [origin.id]
        value.tagsToAdd = [" New  Tag "]
        value.tagsToRemove = ["CORE"]
        return value
    }

    init() throws {
        container = try WordNoteV2ServiceTestSupport.container(populated: false)
        let date = WordNoteV2ServiceTestSupport.now.addingTimeInterval(-100)
        origin = .init(courseName: "Original course", createdAt: date, updatedAt: date)
        destination = .init(courseName: "Destination course", createdAt: date, updatedAt: date)
        first = .init(term: "alpha", termType: .word, chineseMeaning: "First meaning; other meaning",
                      englishDefinition: "Original definition", aiContextExplanation: "Original technical meaning",
                      exampleSentence: "Original example", contextSentence: "Original context", courseID: origin.id,
                      tags: [" Core ", "core", "Keep"], nextReviewAt: nil, createdAt: date, updatedAt: date)
        second = .init(term: "beta", termType: .word, chineseMeaning: "Second meaning", courseID: origin.id,
                       tags: ["Keep"], nextReviewAt: nil, createdAt: date, updatedAt: date)
        for course in [origin, destination] { container.mainContext.insert(course) }
        for term in [first, second] {
            container.mainContext.insert(term)
            container.mainContext.insert(WordNoteSchemaV2.TermCourseLinkModel(termID: term.id, courseID: origin.id, createdAt: date))
        }
        try container.mainContext.save()
        history = try .init(container: container)
        service = try .init(container: container, undoHistory: history)
    }

    func plan(service: WordNoteV2ContentService? = nil) throws -> WordNoteV2OrganizationPlan {
        try (service ?? self.service).makeOrganizationPlan(termIDs: ids, changes: changes)
    }

    func snapshot() throws -> WordNoteSnapshotV2Payload { try WordNoteV2ServiceTestSupport.snapshot(container) }
}
