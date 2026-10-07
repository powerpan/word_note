import CryptoKit
import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class FrozenV1StoreTests: XCTestCase {
    func testFixtureBytesRemainFrozen() throws {
        let data = try Data(contentsOf: fixtureURL())
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "92f4003123fb65a7763f7baf646f3558916e74ebe807832ddf51a7f94398b7de")
    }

    func testCurrentContainerReadsAllFrozenV1EntitiesAndReferences() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "wordnote-v1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "fixture.store")
        try FileManager.default.copyItem(at: fixtureURL(), to: storeURL)
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let container = try ModelContainer(
            for: schema, migrationPlan: WordNoteMigrationPlan.self,
            configurations: [ModelConfiguration("Fixture", schema: schema, url: storeURL)]
        )
        let context = container.mainContext
        let courses = try context.fetch(FetchDescriptor<CourseModel>())
        let terms = try context.fetch(FetchDescriptor<TermModel>())
        let records = try context.fetch(FetchDescriptor<InputRecordModel>())
        let candidates = try context.fetch(FetchDescriptor<CandidateTermModel>())
        let events = try context.fetch(FetchDescriptor<ReviewEventModel>())
        XCTAssertEqual(courses.count, 2)
        XCTAssertEqual(terms.count, 4)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(events.count, 1)
        let courseIDs = Set(courses.map(\.id))
        let recordIDs = Set(records.map(\.id))
        let termIDs = Set(terms.map(\.id))
        XCTAssertTrue(terms.allSatisfy { $0.courseID.map(courseIDs.contains) == true })
        XCTAssertTrue(candidates.allSatisfy { recordIDs.contains($0.inputRecordID) && $0.status == .pending })
        XCTAssertTrue(events.allSatisfy { termIDs.contains($0.termID) })
        XCTAssertEqual(events.first?.reviewedAt, WordNoteTestFixture.referenceDate)
        XCTAssertEqual(terms.first { $0.term == "quick" }?.chineseMeaning, "迅速的；敏捷的；短時間完成的")
        XCTAssertEqual(records.first { $0.rawText == "bounded queue" }?.status, .failed)
        XCTAssertEqual(try DataIntegrityService(modelContext: context).repairDanglingReferences().repairedItemCount, 0)
    }

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "v1", withExtension: "store", subdirectory: "Fixtures"))
    }
}
