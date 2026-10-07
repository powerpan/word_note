import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2CaptureTests: XCTestCase {
    private typealias Support = WordNoteV2ServiceTestSupport

    func testNewCapturePersistsFrozenContextAndQueueWithoutNetwork() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let courseID = try Support.snapshot(container).content.courses[0].id
        let request = WordNoteCaptureRequest(
            rawText: "  新的表達  ", courseID: courseID, sourceType: .book, note: "  source note  ",
            intent: .chineseToEnglish, capturedVia: .floatingQuickAdd
        )
        let result = try service.capture(request, at: Support.now)
        let id = try Support.inputID(result)
        let record = try Support.record(id, in: container)
        XCTAssertFalse(result.isReplay)
        XCTAssertEqual(record.rawText, "新的表達")
        XCTAssertEqual(record.note, "source note")
        XCTAssertEqual(record.courseID, courseID)
        XCTAssertEqual(record.captureID, request.captureID)
        XCTAssertEqual(record.capturedViaRaw, "floatingQuickAdd")
        XCTAssertEqual(record.lookupIntentRaw, "chineseToEnglish")
        XCTAssertEqual(record.resolvedLookupDirectionRaw, "chineseToEnglish")
        XCTAssertEqual(record.directionDetectorVersion, "explicit-v1")
        XCTAssertEqual(record.statusRaw, "draft")
        XCTAssertEqual(record.queueStateRaw, "queued")
        XCTAssertEqual(record.analysisGeneration, 1)
        XCTAssertEqual(record.revision, 0)
        XCTAssertEqual(record.createdAt, Support.now)
        XCTAssertNil(record.attemptID)
        XCTAssertEqual(try Support.snapshot(container).content.candidates.count, 3)
    }

    func testSaveOnlyDoesNotTreatExistingTextAsAnExplicitRepeatLookup() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let result = try service.capture(.init(rawText: "quick"), analyze: false, at: Support.now)
        let record = try Support.record(Support.inputID(result), in: container)
        XCTAssertEqual(record.queueStateRaw, "none")
        XCTAssertEqual(record.analysisGeneration, 0)
        XCTAssertEqual(try Support.term("quick", in: container).duplicateHitCount, 0)
        XCTAssertTrue(try Support.snapshot(container).lookupEvents.isEmpty)
    }

    func testSameSubmissionReplayAcrossServiceInstancesDoesNotWriteTwice() throws {
        let container = try Support.container()
        var saveCount = 0
        let service = try WordNoteV2ContentService(container: container, save: { context in saveCount += 1; try context.save() })
        let request = WordNoteCaptureRequest(rawText: "new queued expression")
        let first = try service.capture(request, at: Support.now)
        let again = try service.capture(request, at: Support.now.addingTimeInterval(1))
        let otherService = try WordNoteV2ContentService(container: container)
        let last = try otherService.capture(request, at: Support.now.addingTimeInterval(2))
        XCTAssertEqual(first.destination, again.destination)
        XCTAssertEqual(first.destination, last.destination)
        XCTAssertTrue(again.isReplay)
        XCTAssertTrue(last.isReplay)
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(try Support.snapshot(container).content.inputRecords.count, 4)
    }

    func testDifferentSubmissionsWithIdenticalQueuedTextKeepTheirOwnContext() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let courses = try Support.snapshot(container).content.courses
        let first = try service.capture(.init(rawText: "new expression", courseID: courses[0].id, note: "one"), at: Support.now)
        let second = try service.capture(.init(rawText: "new expression", courseID: courses[1].id, note: "two"), at: Support.now)
        XCTAssertNotEqual(try Support.inputID(first), try Support.inputID(second))
        XCTAssertEqual(try Support.snapshot(container).content.inputRecords.count, 5)
        XCTAssertEqual(try Support.record(Support.inputID(first), in: container).courseID, courses[0].id)
        XCTAssertEqual(try Support.record(Support.inputID(second), in: container).note, "two")
    }

    func testCaptureIDCannotBeReusedForDifferentContext() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let request = WordNoteCaptureRequest(rawText: "original", note: "note")
        _ = try service.capture(request, at: Support.now)
        let before = try Support.snapshot(container)
        let collisions = [
            WordNoteCaptureRequest(captureID: request.captureID, rawText: "changed", note: "note"),
            WordNoteCaptureRequest(captureID: request.captureID, rawText: "original", note: "changed"),
            WordNoteCaptureRequest(captureID: request.captureID, rawText: "original", note: "note", intent: .englishToChinese),
            WordNoteCaptureRequest(captureID: request.captureID, rawText: "original", note: "note", capturedVia: .floatingQuickAdd)
        ]
        for collision in collisions {
            XCTAssertThrowsError(try service.capture(collision, at: Support.now)) {
                XCTAssertEqual($0 as? WordNoteV2ContentError, .captureConflict)
            }
        }
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testExactEnglishHitAddsOccurrenceEventAndCourseWithoutInboxOrContentOverwrite() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let before = try Support.snapshot(container)
        let courseID = before.content.courses[1].id
        let originalTerm = try Support.term("quick", in: container)
        let request = WordNoteCaptureRequest(rawText: "QUICK", courseID: courseID, sourceType: .paper, note: "read again", capturedVia: .floatingQuickAdd)
        let result = try service.capture(request, at: Support.now)
        XCTAssertEqual(result.destination, .vocabulary(id: originalTerm.id, term: "quick", chineseMeaning: originalTerm.chineseMeaning, englishDefinition: originalTerm.englishDefinition))
        let after = try Support.snapshot(container)
        XCTAssertEqual(after.content.inputRecords, before.content.inputRecords)
        XCTAssertEqual(after.content.candidates, before.content.candidates)
        XCTAssertEqual(after.content.reviewEvents, before.content.reviewEvents)
        XCTAssertEqual(after.occurrences.count, 1)
        XCTAssertEqual(after.lookupEvents.count, 1)
        XCTAssertEqual(after.courseLinks.count, before.courseLinks.count + 1)
        XCTAssertEqual(after.occurrences[0].captureID, request.captureID)
        XCTAssertEqual(after.occurrences[0].rawTextSnapshot, "QUICK")
        XCTAssertNil(after.occurrences[0].sourceRecordID)
        XCTAssertEqual(after.occurrences[0].capturedViaRaw, "floatingQuickAdd")
        XCTAssertEqual(after.lookupEvents[0].occurrenceID, after.occurrences[0].id)
        XCTAssertEqual(originalTerm.wrongCount, 1)
        XCTAssertEqual(originalTerm.duplicateHitCount, 1)
        XCTAssertEqual(originalTerm.nextReviewAt, Support.now)
        XCTAssertEqual(originalTerm.masteryLevel, .vague)
        XCTAssertEqual(originalTerm.importance, .high)
        XCTAssertEqual(originalTerm.correctStreak, 0)
        XCTAssertEqual(originalTerm.revision, 1)
        XCTAssertEqual(originalTerm.counterSemanticsVersionRaw, "legacyMixed")
        XCTAssertEqual(originalTerm.chineseMeaning, before.content.terms.first { $0.id == originalTerm.id }?.chineseMeaning)
    }

    func testExactHitReplaySurvivesSnapshotRestoreWithoutAdditionalCounters() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let request = WordNoteCaptureRequest(rawText: "quick")
        let first = try service.capture(request, at: Support.now)
        let payload = try Support.snapshot(container)
        let restored = try Support.container(populated: false)
        try payload.populateEmptyStore(restored.mainContext)
        let restoredService = try WordNoteV2ContentService(container: restored)
        let replay = try restoredService.capture(request, at: Support.now.addingTimeInterval(800))
        XCTAssertTrue(replay.isReplay)
        XCTAssertEqual(first.destination, replay.destination)
        XCTAssertEqual(try Support.snapshot(restored), payload)
    }

    func testNewExactHitCapturesPreserveLegacyWrongCountCooldown() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        _ = try service.capture(.init(rawText: "quick"), at: Support.now)
        _ = try service.capture(.init(rawText: "quick"), at: Support.now.addingTimeInterval(30))
        _ = try service.capture(.init(rawText: "quick"), at: Support.now.addingTimeInterval(630))
        let term = try Support.term("quick", in: container)
        XCTAssertEqual(term.duplicateHitCount, 3)
        XCTAssertEqual(term.wrongCount, 2)
        XCTAssertEqual(term.revision, 3)
        XCTAssertEqual(try Support.snapshot(container).occurrences.count, 3)
        XCTAssertEqual(try Support.snapshot(container).lookupEvents.count, 3)
    }

    func testChineseOrExplicitChineseDirectionDoesNotMatchFormalEnglishTerm() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let chinese = try service.capture(.init(rawText: "過擬合"), at: Support.now)
        let override = try service.capture(.init(rawText: "quick", intent: .chineseToEnglish), at: Support.now)
        XCTAssertEqual(try Support.record(Support.inputID(chinese), in: container).resolvedLookupDirectionRaw, "chineseToEnglish")
        XCTAssertEqual(try Support.record(Support.inputID(override), in: container).resolvedLookupDirectionRaw, "chineseToEnglish")
        XCTAssertTrue(try Support.snapshot(container).lookupEvents.isEmpty)
        XCTAssertEqual(try Support.term("quick", in: container).duplicateHitCount, 0)
    }

    func testInvalidInputAndDanglingCourseAreRejectedWithoutCreatingWork() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let before = try Support.snapshot(container)
        XCTAssertThrowsError(try service.capture(.init(rawText: " \n "), at: Support.now))
        XCTAssertThrowsError(try service.capture(.init(rawText: String(repeating: "a", count: 8_001)), at: Support.now))
        XCTAssertThrowsError(try service.capture(.init(rawText: "new", courseID: UUID()), at: Support.now))
        XCTAssertThrowsError(try service.capture(.init(rawText: "new", capturedVia: .legacy), at: Support.now))
        XCTAssertThrowsError(try service.capture(.init(rawText: "new"), at: Date(timeIntervalSince1970: .infinity)))
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testAmbiguousStoredHeadwordDoesNotChooseAnArbitraryTerm() throws {
        let container = try Support.container()
        container.mainContext.insert(WordNoteSchemaV2.TermModel(term: "quick", termType: .word, chineseMeaning: "另一條釋義"))
        try container.mainContext.save()
        let service = try WordNoteV2ContentService(container: container)
        let before = try Support.snapshot(container)
        XCTAssertThrowsError(try service.capture(.init(rawText: "quick"), at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV2ContentError, .ambiguousExactMatch)
        }
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testSaveFailureRollsBackBothNewCaptureAndLocalHitRelationsAndCounters() throws {
        let container = try Support.container()
        let failing = try WordNoteV2ContentService(container: container, save: { _ in throw Support.Failure.save })
        let before = try Support.snapshot(container)
        XCTAssertThrowsError(try failing.capture(.init(rawText: "new expression"), at: Support.now)) {
            XCTAssertEqual($0 as? Support.Failure, .save)
        }
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertThrowsError(try failing.capture(.init(rawText: "quick", courseID: before.content.courses[1].id), at: Support.now)) {
            XCTAssertEqual($0 as? Support.Failure, .save)
        }
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testCounterOverflowRollsBackNewEventAndOccurrence() throws {
        let container = try Support.container()
        let term = try Support.term("quick", in: container)
        term.wrongCount = 1_000_000_000
        try container.mainContext.save()
        let before = try Support.snapshot(container)
        let service = try WordNoteV2ContentService(container: container)
        XCTAssertThrowsError(try service.capture(.init(rawText: "quick"), at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV2ContentError, .counterLimit)
        }
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testUncommittedUserChangesAreNotSavedOrRolledBackByService() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let term = try Support.term("quick", in: container)
        term.chineseMeaning = "unsaved edit"
        XCTAssertThrowsError(try service.capture(.init(rawText: "new"), at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV2ContentError, .unsavedChanges)
        }
        XCTAssertEqual(term.chineseMeaning, "unsaved edit")
        XCTAssertTrue(container.mainContext.hasChanges)
        container.mainContext.rollback()
    }
}
