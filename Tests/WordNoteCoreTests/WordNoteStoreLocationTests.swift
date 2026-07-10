import Foundation
import SwiftData
import XCTest
@testable import WordNoteCore

final class WordNoteStoreLocationTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: "word-note-store-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL,
           FileManager.default.fileExists(atPath: temporaryDirectoryURL.path) {
            try FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
    }

    func testPrepareStoreLocationBacksUpAndCopiesLegacyStore() throws {
        let legacyStoreURL = temporaryDirectoryURL.appending(path: "default.store")
        try Data("legacy-store".utf8).write(to: legacyStoreURL)
        try Data("legacy-wal".utf8).write(to: URL(fileURLWithPath: legacyStoreURL.path + "-wal"))

        let manager = WordNoteStoreLocationManager(applicationSupportURL: temporaryDirectoryURL)
        let result = try manager.prepareStoreLocation()

        XCTAssertTrue(result.migratedLegacyStore)
        XCTAssertEqual(result.storeURL, manager.storeURL)
        XCTAssertEqual(try Data(contentsOf: manager.storeURL), Data("legacy-store".utf8))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: manager.storeURL.path + "-wal")),
            Data("legacy-wal".utf8)
        )

        let backupDirectoryURL = try XCTUnwrap(result.backupDirectoryURL)
        XCTAssertEqual(
            try Data(contentsOf: backupDirectoryURL.appending(path: "default.store")),
            Data("legacy-store".utf8)
        )

        let permissions = try FileManager.default.attributesOfItem(atPath: manager.storeURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testPrepareStoreLocationDoesNotOverwriteExistingStore() throws {
        let manager = WordNoteStoreLocationManager(applicationSupportURL: temporaryDirectoryURL)
        try FileManager.default.createDirectory(
            at: manager.storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("current-store".utf8).write(to: manager.storeURL)
        try Data("legacy-store".utf8).write(to: manager.legacyStoreURL)

        let result = try manager.prepareStoreLocation()

        XCTAssertFalse(result.migratedLegacyStore)
        XCTAssertNil(result.backupDirectoryURL)
        XCTAssertEqual(try Data(contentsOf: manager.storeURL), Data("current-store".utf8))
    }

    @MainActor
    func testVersionedContainerOpensCopiedLegacyStoreWithoutLosingTerms() throws {
        let schema = Schema(WordNoteSchemaV1.models)
        let legacyURL = temporaryDirectoryURL.appending(path: "default.store")
        var legacyContainer: ModelContainer? = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration("Legacy", schema: schema, url: legacyURL)]
        )
        var legacyContext: ModelContext? = legacyContainer?.mainContext
        legacyContext?.insert(
            TermModel(
                term: "regularization",
                termType: .word,
                chineseMeaning: "正則化"
            )
        )
        try legacyContext?.save()
        legacyContext = nil
        legacyContainer = nil

        let manager = WordNoteStoreLocationManager(applicationSupportURL: temporaryDirectoryURL)
        let migration = try manager.prepareStoreLocation()
        XCTAssertTrue(migration.migratedLegacyStore)

        let versionedSchema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let container = try ModelContainer(
            for: versionedSchema,
            migrationPlan: WordNoteMigrationPlan.self,
            configurations: [
                ModelConfiguration("WordNote", schema: versionedSchema, url: manager.storeURL)
            ]
        )

        let terms = try container.mainContext.fetch(FetchDescriptor<TermModel>())
        XCTAssertEqual(terms.map(\.normalizedTerm), ["regularization"])
    }
}
