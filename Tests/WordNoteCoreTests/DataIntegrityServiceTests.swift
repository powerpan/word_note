import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class DataIntegrityServiceTests: XCTestCase {
    func testRepairDanglingReferencesRemovesOrphansAndClearsInvalidIDs() throws {
        let context = ModelContext(try makeInMemoryContainer())
        let (record, _, term, _) = try seedDanglingReferences(in: context)
        let report = try DataIntegrityService(modelContext: context).repairDanglingReferences()

        XCTAssertEqual(report.deletedOrphanCandidates, 1)
        XCTAssertEqual(report.deletedOrphanReviewEvents, 1)
        XCTAssertEqual(report.clearedSourceRecordReferences, 1)
        XCTAssertEqual(report.clearedCourseReferences, 2)
        XCTAssertNil(record.courseID)
        XCTAssertNil(term.courseID)
        XCTAssertNil(term.sourceRecordID)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CandidateTermModel>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ReviewEventModel>()).isEmpty)
    }

    func testStartupInspectionReportsEveryBrokenReferenceWithoutDeletingOrClearingAnything() throws {
        let context = ModelContext(try makeInMemoryContainer())
        let (record, candidate, term, event) = try seedDanglingReferences(in: context)
        let recordCourse = record.courseID
        let termCourse = term.courseID
        let termSource = term.sourceRecordID
        let service = DataIntegrityService(modelContext: context)
        let report = try service.inspectDanglingReferences()
        XCTAssertEqual(report.issueCount, 5)
        XCTAssertEqual(report.orphanCandidateIDs, [candidate.id])
        XCTAssertEqual(report.orphanReviewEventIDs, [event.id])
        XCTAssertEqual(report.missingSourceTermIDs, [term.id])
        XCTAssertEqual(report.missingCourseRecordIDs, [record.id])
        XCTAssertEqual(report.missingCourseTermIDs, [term.id])
        XCTAssertThrowsError(try service.validateBeforeOpening()) {
            XCTAssertEqual($0 as? DataIntegrityStartupError, .unresolvedReferences(report))
        }
        XCTAssertEqual(record.courseID, recordCourse)
        XCTAssertEqual(term.courseID, termCourse)
        XCTAssertEqual(term.sourceRecordID, termSource)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CandidateTermModel>()).map(\.id), [candidate.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ReviewEventModel>()).map(\.id), [event.id])
        XCTAssertEqual(candidate.chineseMeaning, "孤立")
        XCTAssertFalse(context.hasChanges)
    }

    func testHealthyStartupInspectionKeepsCompleteSnapshotUnchanged() throws {
        let context = ModelContext(try makeInMemoryContainer())
        try WordNoteTestFixture.populated.populate(context)
        let before = try WordNoteSnapshotPayload.capture(from: context)
        let service = DataIntegrityService(modelContext: context)
        XCTAssertEqual(try service.inspectDanglingReferences().issueCount, 0)
        XCTAssertNoThrow(try service.validateBeforeOpening())
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: context), before)
        XCTAssertFalse(context.hasChanges)
    }

    func testInspectionAndExplicitLegacyRepairRejectUncommittedEditsWithoutDiscardingThem() throws {
        let context = ModelContext(try makeInMemoryContainer())
        let record = InputRecordModel(rawText: "Uncommitted text")
        context.insert(record)
        let service = DataIntegrityService(modelContext: context)
        XCTAssertThrowsError(try service.inspectDanglingReferences()) {
            XCTAssertEqual($0 as? DataIntegrityStartupError, .unsavedChanges)
        }
        XCTAssertThrowsError(try service.repairDanglingReferences()) {
            XCTAssertEqual($0 as? DataIntegrityStartupError, .unsavedChanges)
        }
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(record.rawText, "Uncommitted text")
        context.rollback()
    }

    func testLegacyIntegrityServiceRefusesV2InsteadOfFetchingWrongModels() throws {
        let container = try WordNoteV2ServiceTestSupport.container()
        let service = DataIntegrityService(modelContext: container.mainContext)
        XCTAssertThrowsError(try service.validateBeforeOpening()) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema)
        }
        XCTAssertThrowsError(try service.repairDanglingReferences()) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema)
        }
    }

    func testRejectedStartupLeavesBrokenSQLiteRowsAvailableAfterReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "wordnote-startup-integrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "original.store")
        func container() throws -> ModelContainer {
            let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
            return try ModelContainer(for: schema, configurations: [ModelConfiguration("StartupIntegrity", schema: schema, url: url)])
        }
        let before = try autoreleasepool {
            let original = try container()
            original.mainContext.autosaveEnabled = false
            _ = try seedDanglingReferences(in: original.mainContext)
            let service = DataIntegrityService(modelContext: original.mainContext)
            let report = try service.inspectDanglingReferences()
            XCTAssertThrowsError(try service.validateBeforeOpening())
            return report
        }
        let reopened = try container()
        XCTAssertEqual(try DataIntegrityService(modelContext: reopened.mainContext).inspectDanglingReferences(), before)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<CandidateTermModel>()), 1)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<ReviewEventModel>()), 1)
    }

    private func seedDanglingReferences(
        in context: ModelContext
    ) throws -> (InputRecordModel, CandidateTermModel, TermModel, ReviewEventModel) {
        let missingRecordID = UUID()
        let missingCourseID = UUID()
        let missingTermID = UUID()

        let record = InputRecordModel(
            rawText: "regularization",
            status: .draft,
            courseID: missingCourseID
        )
        let orphanCandidate = CandidateTermModel(
            inputRecordID: missingRecordID,
            term: "orphan",
            termType: .word,
            needToLearn: true,
            importance: .medium,
            category: .general,
            chineseMeaning: "孤立"
        )
        let term = TermModel(
            term: "gradient descent",
            termType: .phrase,
            chineseMeaning: "梯度下降",
            courseID: missingCourseID,
            sourceRecordID: missingRecordID
        )
        let orphanEvent = ReviewEventModel(
            termID: missingTermID,
            mode: .englishToChinese,
            feedback: .good,
            previousMasteryLevel: .new,
            newMasteryLevel: .familiar
        )

        context.insert(record)
        context.insert(orphanCandidate)
        context.insert(term)
        context.insert(orphanEvent)
        try context.save()

        return (record, orphanCandidate, term, orphanEvent)
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(WordNoteSchemaV1.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
