import XCTest
@testable import WordNoteCore

final class WordNoteTagsTests: XCTestCase {
    func testNewLabelNormalizesWhitespaceButPreservesCaseAndCommas() throws {
        XCTAssertEqual(try WordNoteTags.newLabel(" \tCS  50\nWords "), "CS 50 Words")
        XCTAssertEqual(try WordNoteTags.newLabel("AI, ML"), "AI, ML")
        XCTAssertEqual(WordNoteTags.key(" Core  WORDS "), "core words")
    }

    func testNewLabelRejectsBlankControlCharactersAndOverlongText() {
        for text in ["", " \n ", "A\u{0000}B", "A\u{001B}B", String(repeating: "a", count: 81)] {
            XCTAssertThrowsError(try WordNoteTags.newLabel(text))
        }
        XCTAssertNoThrow(try WordNoteTags.newLabel(String(repeating: "詞", count: 80)))
    }

    func testExistingOptionsAreStableAndDoNotRejectLongLegacyTags() {
        let long = String(repeating: "a", count: 81)
        let tags = ["core", "Core", " ", long, "CORE"]
        XCTAssertEqual(WordNoteTags.options(tags), WordNoteTags.options(tags.reversed()))
        XCTAssertEqual(WordNoteTags.options(tags).map(\.label), [long, "CORE"])
    }
}
