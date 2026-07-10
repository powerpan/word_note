import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class DataIntegrityServiceTests: XCTestCase {
    func testRepairDanglingReferencesRemovesOrphansAndClearsInvalidIDs() throws {
        let context = ModelContext(try makeInMemoryContainer())
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

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(WordNoteSchemaV1.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
