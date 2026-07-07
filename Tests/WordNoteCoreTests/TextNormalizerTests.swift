import XCTest
@testable import WordNoteCore

final class TextNormalizerTests: XCTestCase {
    func testNormalizedTrimsWhitespaceCollapsesRunsAndLowercases() {
        XCTAssertEqual(
            TextNormalizer.normalized("  Latent   Representation\n "),
            "latent representation"
        )
    }

    func testBlankDetection() {
        XCTAssertTrue(TextNormalizer.isBlank(" \n\t "))
        XCTAssertFalse(TextNormalizer.isBlank("regularization"))
    }
}
