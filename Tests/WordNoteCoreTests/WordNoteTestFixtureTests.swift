import SwiftData
import SQLite3
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteTestFixtureTests: XCTestCase {
    func testEmptyFixtureDoesNotInsertAnything() throws {
        let container = try makeContainer()
        try WordNoteTestFixture.empty.populate(container.mainContext)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<TermModel>()), 0)
    }

    func testFixtureRejectsNonEmptyStoreWithoutChangingIt() throws {
        let container = try makeContainer()
        try WordNoteTestFixture.populated.populate(container.mainContext)
        XCTAssertThrowsError(try WordNoteTestFixture.populated.populate(container.mainContext))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<TermModel>()), 4)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<ReviewEventModel>()), 1)
    }

    func testPersistentV1FixtureCanBeReopenedWithoutChangingIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "fixture.store")
        let ids: Set<UUID> = try autoreleasepool {
            let container = try makeContainer(url: url)
            try WordNoteTestFixture.populated.populate(container.mainContext)
            return Set(try container.mainContext.fetch(FetchDescriptor<TermModel>()).map(\.id))
        }
        if let exportPath = ProcessInfo.processInfo.environment["WORD_NOTE_EXPORT_V1_FIXTURE"] {
            try exportSQLite(from: url, to: URL(fileURLWithPath: exportPath))
        }
        let reopened = try makeContainer(url: url)
        let context = reopened.mainContext
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<TermModel>()).map(\.id)), ids)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CourseModel>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InputRecordModel>()), 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CandidateTermModel>()), 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewEventModel>()), 1)
        XCTAssertEqual(try DataIntegrityService(modelContext: context).repairDanglingReferences().repairedItemCount, 0)
    }

    func testMixedDuplicateBaselineRejectsWholeBatchWithoutPartialInsertion() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try WordNoteTestFixture.populated.populate(context)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<InputRecordModel>()).first {
            $0.rawText == "A quick response improves throughput."
        })
        let candidates = try context.fetch(FetchDescriptor<CandidateTermModel>()).filter { $0.inputRecordID == record.id }
        XCTAssertEqual(candidates.count, 2)
        XCTAssertThrowsError(try VocabularyService(modelContext: context).createTerms(from: candidates, sourceRecord: record))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TermModel>()), 4)
        XCTAssertTrue(candidates.allSatisfy { $0.status == .pending })
        XCTAssertEqual(record.status, .analyzed)
    }

    func testChineseFixtureReturnsEnglishSubjectWithoutNetwork() {
        let result = WordNoteTestFixture.analysisResult(for: AIAnalysisRequest(rawText: "過擬合"))
        XCTAssertEqual(result.candidates.first?.term, "overfitting")
        XCTAssertEqual(result.model, "offline-ui-fixture")
    }

    func testLearningFixtureAddsLongListsWithoutChangingThePopulatedBaseline() throws {
        let baseContainer = try makeContainer(), longContainer = try makeContainer()
        try WordNoteTestFixture.populated.populate(baseContainer.mainContext)
        try WordNoteTestFixture.learning.populate(longContainer.mainContext)
        let base = try WordNoteSnapshotPayload.capture(from: baseContainer.mainContext)
        let long = try WordNoteSnapshotPayload.capture(from: longContainer.mainContext)
        XCTAssertEqual(long.terms.count, 44)
        XCTAssertEqual(long.inputRecords.count, 55)
        XCTAssertEqual(long.candidates, base.candidates)
        XCTAssertEqual(long.reviewEvents, base.reviewEvents)
        XCTAssertEqual(long.courses, base.courses)
        XCTAssertEqual(long.terms.filter { item in base.terms.contains { $0.id == item.id } }, base.terms)
        XCTAssertEqual(long.inputRecords.filter { item in base.inputRecords.contains { $0.id == item.id } }, base.inputRecords)
        let v3 = try WordNoteV2ToV3Migration.convert(WordNoteV1ToV2Migration.convert(long).payload, at: WordNoteTestFixture.referenceDate)
        let overview = try LearningOverviewBuilder(payload: v3).overview(mode: .englishToChinese,
            studyTimeZoneID: "Asia/Hong_Kong", at: WordNoteTestFixture.referenceDate.addingTimeInterval(86400))
        XCTAssertEqual(overview.pendingRecords.count, 15)
        XCTAssertEqual(overview.recentOccurrences.count, 40)
        XCTAssertEqual(overview.statistics.workload.readyCards, 44)
    }

    private func makeContainer(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let configuration = url.map { ModelConfiguration("Fixture", schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, migrationPlan: WordNoteMigrationPlan.self, configurations: [configuration])
    }

    private func exportSQLite(from source: URL, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var sourceDB: OpaquePointer?
        var destinationDB: OpaquePointer?
        guard sqlite3_open_v2(source.path, &sourceDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let sourceDB { sqlite3_close(sourceDB) }
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close(sourceDB) }
        guard sqlite3_open(destination.path, &destinationDB) == SQLITE_OK else {
            if let destinationDB { sqlite3_close(destinationDB) }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(destinationDB) }
        guard let backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") else {
            throw CocoaError(.fileWriteUnknown)
        }
        let status = sqlite3_backup_step(backup, -1)
        let finishStatus = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finishStatus == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
