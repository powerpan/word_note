import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class InputRecordServiceTests: XCTestCase {
    func testCreateDraftPersistsTrimmedRecord() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let courseID = UUID()
        let service = InputRecordService(modelContext: context)

        let record = try service.createDraft(
            rawText: "  latent representation  ",
            courseID: courseID,
            sourceType: .paper,
            note: "  VAE lecture  "
        )

        XCTAssertEqual(record.rawText, "latent representation")
        XCTAssertEqual(record.normalizedText, "latent representation")
        XCTAssertEqual(record.courseID, courseID)
        XCTAssertEqual(record.sourceType, .paper)
        XCTAssertEqual(record.note, "VAE lecture")
        XCTAssertEqual(record.status, .draft)

        let records = try context.fetch(FetchDescriptor<InputRecordModel>())
        XCTAssertEqual(records.count, 1)
    }

    func testCreateDraftRejectsBlankRawText() throws {
        let context = ModelContext(try makeInMemoryContainer())
        let service = InputRecordService(modelContext: context)

        XCTAssertThrowsError(
            try service.createDraft(rawText: " \n ", courseID: nil, sourceType: .other, note: nil)
        ) { error in
            XCTAssertEqual(error as? InputRecordValidationError, .blankRawText)
        }
    }

    func testIgnoreAndDeletePersistChanges() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let service = InputRecordService(modelContext: context)
        let record = try service.createDraft(
            rawText: "gradient descent",
            courseID: nil,
            sourceType: .class,
            note: nil
        )

        try service.ignore(record)
        XCTAssertEqual(record.status, .ignored)

        try service.delete(record)
        let records = try context.fetch(FetchDescriptor<InputRecordModel>())
        XCTAssertTrue(records.isEmpty)
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            CourseModel.self,
            InputRecordModel.self,
            CandidateTermModel.self,
            TermModel.self,
            ReviewEventModel.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
