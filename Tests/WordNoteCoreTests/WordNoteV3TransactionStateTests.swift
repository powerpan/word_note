import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3TransactionStateTests: XCTestCase {
    private typealias V3 = WordNoteSchemaV3
    private typealias Payload = WordNoteSnapshotV3Payload

    func testReadersAndWritersShareValidatedValuesWithoutRepeatedFullReads() throws {
        let container = try WordNoteV3ServiceTestSupport.container()
        let first = try WordNoteV3ContentService(container: container)
        let second = try WordNoteV3ReviewService(container: container)
        _ = try first.transaction { try first.snapshot() }
        _ = try second.resumableSession()
        _ = try first.capture(.init(rawText: "new isolated capture"))
        _ = try first.capture(.init(rawText: "quick"))
        _ = try second.cardLearningIndex(studyTimeZoneID: "Asia/Hong_Kong")
        XCTAssertTrue(first.transactionState === second.content.transactionState)
        XCTAssertEqual(first.transactionState.fullReadCount, 1)
        try assertMatchesStore(first, container)
    }

    func testDeltaIncludesEveryEntityAndMetadataProjection() throws {
        let container = try V3ReviewTestSupport.seeded(V3ReviewTestSupport.payload())
        let service = try WordNoteV3ContentService(container: container)
        let date = V3ReviewTestSupport.now.addingTimeInterval(1)
        try service.transaction {
            try XCTUnwrap(service.fetch(V3.CourseModel.self).first).courseDescription = "updated course"
            try XCTUnwrap(service.fetch(V3.InputRecordModel.self).first).note = "updated input"
            try XCTUnwrap(service.fetch(V3.CandidateTermModel.self).first).chineseMeaning = "updated candidate"
            try XCTUnwrap(service.fetch(V3.TermModel.self).first).chineseMeaning = "updated term"
            try XCTUnwrap(service.fetch(V3.ReviewEventModel.self).first).reviewedAt = date
            try XCTUnwrap(service.fetch(V3.TermOccurrenceModel.self).first).note = "updated occurrence"
            try XCTUnwrap(service.fetch(V3.TermCourseLinkModel.self).first).createdAt = date
            try XCTUnwrap(service.fetch(V3.LookupEventModel.self).first).createdAt = date
            try XCTUnwrap(service.fetch(V3.ReviewCardModel.self).first).updatedAt = date
            try XCTUnwrap(service.fetch(V3.ReviewSessionModel.self).first).updatedAt = date
            try XCTUnwrap(service.fetch(V3.ReviewSessionItemModel.self).first).updatedAt = date
        }
        try assertMatchesStore(service, container)
        XCTAssertEqual(service.transactionState.fullReadCount, 1)
    }

    func testCascadeDeletionRemovesValuesAndRelatedMetadata() throws {
        let container = try V3ReviewTestSupport.seeded(V3ReviewTestSupport.payload())
        let service = try WordNoteV3ContentService(container: container)
        let term = try XCTUnwrap(service.fetch(V3.TermModel.self).first)
        _ = try service.transaction { try service.snapshot() }
        try service.deleteTerm(term.id, expectedRevision: term.revision)
        try assertMatchesStore(service, container)
        XCTAssertEqual(service.transactionState.fullReadCount, 1)
    }

    func testPrimaryIDChangesCannotHideDuplicateOrBrokenReferences() throws {
        let container = try WordNoteV3ServiceTestSupport.container()
        let service = try WordNoteV3ContentService(container: container)
        let before = try Payload.capture(from: container.mainContext)
        let terms = try service.fetch(V3.TermModel.self)
        XCTAssertThrowsError(try service.transaction { terms[0].id = terms[1].id })
        XCTAssertEqual(try Payload.capture(from: container.mainContext), before)
        try assertMatchesStore(service, container)
    }

    func testValidPrimaryIDChangeReplacesOldValueInsteadOfAppending() throws {
        let container = try WordNoteV3ServiceTestSupport.container(populated: false)
        let course = V3.CourseModel(courseName: "Unreferenced")
        container.mainContext.insert(course)
        try container.mainContext.save()
        let service = try WordNoteV3ContentService(container: container)
        let newID = UUID()
        try service.transaction { course.id = newID }
        XCTAssertEqual(try service.snapshot().content.content.courses.map(\.id), [newID])
        try assertMatchesStore(service, container)
    }

    func testDirectSaveInvalidatesCacheAndPreexistingDamageIsNotRepairedByMutation() throws {
        let container = try WordNoteV3ServiceTestSupport.container()
        let service = try WordNoteV3ContentService(container: container)
        _ = try service.transaction { try service.snapshot() }
        let term = try XCTUnwrap(service.fetch(V3.TermModel.self).first)
        term.chineseMeaning = "changed outside the service"
        try container.mainContext.save()
        try assertMatchesStore(service, container)
        XCTAssertEqual(service.transactionState.fullReadCount, 2)
        term.courseID = UUID()
        try container.mainContext.save()
        var enteredBody = false
        XCTAssertThrowsError(try service.transaction { enteredBody = true; term.courseID = nil })
        XCTAssertFalse(enteredBody)
        XCTAssertNotNil(term.courseID)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testOtherContextSaveInvalidatesButIndependentContainerDoesNot() throws {
        let container = try WordNoteV3ServiceTestSupport.container()
        let service = try WordNoteV3ContentService(container: container)
        _ = try service.transaction { try service.snapshot() }
        let other = ModelContext(container)
        other.insert(V3.CourseModel(courseName: "Another context"))
        try other.save()
        try assertMatchesStore(service, container)
        XCTAssertEqual(service.transactionState.fullReadCount, 2)
        let independent = try WordNoteV3ServiceTestSupport.container()
        _ = try WordNoteV3ContentService(container: independent).capture(.init(rawText: "unrelated input"))
        try assertMatchesStore(service, container)
        XCTAssertEqual(service.transactionState.fullReadCount, 2)
    }

    func testFailedSaveAndRetryDoNotPublishSpeculativeValues() throws {
        let container = try WordNoteV3ServiceTestSupport.container()
        let before = try Payload.capture(from: container.mainContext)
        enum Failure: Error { case save }
        let failing = try WordNoteV3ContentService(container: container, beforeSave: { _ in throw Failure.save })
        let request = WordNoteCaptureRequest(rawText: "quick")
        XCTAssertThrowsError(try failing.capture(request))
        XCTAssertFalse(container.mainContext.hasChanges)
        XCTAssertEqual(try Payload.capture(from: container.mainContext), before)
        let service = try WordNoteV3ContentService(container: container)
        XCTAssertFalse(try service.capture(request).isReplay)
        try assertMatchesStore(service, container)
        XCTAssertTrue(try service.capture(request).isReplay)
    }

    func testBeforeSaveMutationIsValidatedAndUnsavedUserEditIsPreserved() throws {
        let container = try WordNoteV3ServiceTestSupport.container()
        let term = try WordNoteV3ServiceTestSupport.term("quick", in: container)
        let service = try WordNoteV3ContentService(container: container, beforeSave: { _ in term.courseID = UUID() })
        XCTAssertThrowsError(try service.capture(.init(rawText: "fresh capture")))
        try assertMatchesStore(service, container)
        term.chineseMeaning = "unsaved user edit"
        XCTAssertThrowsError(try service.capture(.init(rawText: "fresh capture"))) {
            XCTAssertEqual($0 as? WordNoteV3ContentError, .unsavedChanges)
        }
        XCTAssertEqual(term.chineseMeaning, "unsaved user edit")
        XCTAssertTrue(container.mainContext.hasChanges)
    }

    func testInsertThenDeleteDoesNotPublishAGhostValue() throws {
        let container = try WordNoteV3ServiceTestSupport.container()
        let service = try WordNoteV3ContentService(container: container)
        let before = try Payload.capture(from: container.mainContext)
        try service.transaction {
            let course = V3.CourseModel(courseName: "Temporary")
            container.mainContext.insert(course)
            container.mainContext.delete(course)
        }
        try assertMatchesStore(service, container)
        XCTAssertEqual(try Payload.capture(from: container.mainContext), before)
    }

    func testAnotherContextSaveDuringMutationRejectsStaleCommit() throws {
        let container = try WordNoteV3ServiceTestSupport.container()
        let service = try WordNoteV3ContentService(container: container, beforeSave: { _ in
            let other = ModelContext(container)
            other.insert(V3.CourseModel(courseName: "Independently saved"))
            try other.save()
        })
        XCTAssertThrowsError(try service.capture(.init(rawText: "must not be committed"))) {
            XCTAssertEqual($0 as? WordNoteWriteError, .expiredOperation)
        }
        let snapshot = try Payload.capture(from: container.mainContext)
        XCTAssertFalse(snapshot.content.content.inputRecords.contains { $0.rawText == "must not be committed" })
        XCTAssertTrue(snapshot.content.content.courses.contains { $0.courseName == "Independently saved" })
        try assertMatchesStore(service, container)
    }

    private func assertMatchesStore(_ service: WordNoteV3ContentService, _ container: ModelContainer,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try service.transaction { try service.snapshot().canonicalized },
            try Payload.capture(from: container.mainContext), file: file, line: line)
    }
}
