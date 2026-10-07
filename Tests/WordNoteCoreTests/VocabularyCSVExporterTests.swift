import SwiftData
import XCTest
@testable import WordNoteCore

final class VocabularyCSVExporterTests: XCTestCase {
    func testRFC4180QuotingPreservesCommasQuotesAndMultilineChinese() {
        XCTAssertEqual(VocabularyCSVExporter.escapeCell("中文,\"quote\"\n第二行"), "\"中文,\"\"quote\"\"\n第二行\"")
        XCTAssertEqual(VocabularyCSVExporter.escapeCell(""), "\"\"")
    }

    func testSpreadsheetFormulaPrefixesAreForcedToText() {
        for prefix in ["=", "+", "-", "@", " =", "\t=", "\r\n=", "\u{FEFF}=", "\u{200B}=", "\u{0}="] {
            let cell = VocabularyCSVExporter.escapeCell(prefix + "SUM(1,2)")
            XCTAssertTrue(cell.hasPrefix("\"'"), "Formula prefix was not neutralized")
        }
        XCTAssertEqual(VocabularyCSVExporter.escapeCell("C++"), "\"C++\"")
        XCTAssertEqual(VocabularyCSVExporter.escapeCell("out-of-distribution"), "\"out-of-distribution\"")
    }

    func testNonPrintingControlCharactersBecomeVisibleText() {
        XCTAssertEqual(VocabularyCSVExporter.escapeCell("a\u{0}b\u{7}c"), "\"a\\u{0000}b\\u{0007}c\"")
        XCTAssertEqual(VocabularyCSVExporter.escapeCell("\ttext"), "\"'\ttext\"")
    }

    @MainActor
    func testExportUsesOnlyProvidedTermScopeAndDoesNotIncludeContextOrEvents() throws {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        try WordNoteTestFixture.populated.populate(container.mainContext)
        var payload = try WordNoteSnapshotPayload.capture(from: container.mainContext)
        let privateContext = "CONTEXT_NOT_IN_CSV"
        payload.terms[0].contextSentence = privateContext
        let data = VocabularyCSVExporter.export(terms: [payload.terms[0]], courses: payload.courses)
        let csv = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(csv.hasPrefix("\"English\",\"Chinese\""))
        XCTAssertTrue(csv.contains("\"quick\""))
        XCTAssertTrue(csv.contains("\"Computer Science\""))
        XCTAssertFalse(csv.contains("\"overfitting\""))
        XCTAssertFalse(csv.contains(privateContext))
        XCTAssertFalse(csv.contains("reviewEvents"))
        XCTAssertEqual(csv.components(separatedBy: "\r\n").count, 3)
    }
}
