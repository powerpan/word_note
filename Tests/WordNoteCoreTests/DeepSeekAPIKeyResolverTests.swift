import XCTest
@testable import WordNoteCore

final class DeepSeekAPIKeyResolverTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: "word-note-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL,
           FileManager.default.fileExists(atPath: temporaryDirectoryURL.path) {
            try FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
    }

    func testParseEnvironmentReadsQuotedAndExportedValues() {
        let values = DeepSeekAPIKeyResolver.parseEnvironment(
            content: """
            # local secrets
            export DEEPSEEK_API_KEY="test-key-123"
            OTHER=value
            """
        )

        XCTAssertEqual(values[DeepSeekAPIKeyResolver.environmentVariableName], "test-key-123")
        XCTAssertEqual(values["OTHER"], "value")
    }

    func testResolvePrefersEnvironmentFileOverProcessEnvironment() throws {
        let fileURL = temporaryDirectoryURL.appending(path: "deepseek.env")
        try "DEEPSEEK_API_KEY=\"file-key\"\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let value = DeepSeekAPIKeyResolver.resolve(
            environment: [
                DeepSeekAPIKeyResolver.environmentFileOverrideVariableName: fileURL.path,
                DeepSeekAPIKeyResolver.environmentVariableName: "process-key"
            ]
        )

        XCTAssertEqual(value, "file-key")
    }

    func testEnvironmentFileStoreSavesAndDeletesKey() throws {
        let fileURL = temporaryDirectoryURL.appending(path: "deepseek.env")
        let store = DeepSeekEnvironmentFileStore(fileURL: fileURL)

        try store.save("  saved-key  ")

        XCTAssertEqual(store.load(), "saved-key")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        try store.delete()

        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testEnvironmentFileStoreMigratesProcessKeyOnlyWhenFileIsMissing() throws {
        let fileURL = temporaryDirectoryURL.appending(path: "deepseek.env")
        let store = DeepSeekEnvironmentFileStore(fileURL: fileURL)

        XCTAssertTrue(
            try store.migrateFromProcessEnvironmentIfNeeded(
                environment: [DeepSeekAPIKeyResolver.environmentVariableName: "process-key"]
            )
        )
        XCTAssertEqual(store.load(), "process-key")

        XCTAssertFalse(
            try store.migrateFromProcessEnvironmentIfNeeded(
                environment: [DeepSeekAPIKeyResolver.environmentVariableName: "replacement-key"]
            )
        )
        XCTAssertEqual(store.load(), "process-key")
    }
}
