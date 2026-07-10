import XCTest
@testable import WordNoteCore

final class VocabularyCompletionMatcherTests: XCTestCase {
    func testReturnsSuffixForAnchoredPrefix() {
        let completion = VocabularyCompletionMatcher.bestCompletion(
            for: "qu",
            candidates: ["quick"]
        )

        XCTAssertEqual(
            completion,
            VocabularyCompletion(completedText: "quick", suffix: "ick")
        )
    }

    func testMatchesCaseInsensitivelyAndPreservesTypedPrefix() {
        let completion = VocabularyCompletionMatcher.bestCompletion(
            for: "QU",
            candidates: ["Quick"]
        )

        XCTAssertEqual(
            completion,
            VocabularyCompletion(completedText: "QUick", suffix: "ick")
        )
    }

    func testPrefersShortestRemainingSuffix() {
        let completion = VocabularyCompletionMatcher.bestCompletion(
            for: "qu",
            candidates: ["quickly", "quick sort", "quick"]
        )

        XCTAssertEqual(completion?.completedText, "quick")
    }

    func testUsesStableAlphabeticalTieBreak() {
        let completion = VocabularyCompletionMatcher.bestCompletion(
            for: "ca",
            candidates: ["cat", "car"]
        )

        XCTAssertEqual(completion?.completedText, "car")
    }

    func testCompletesPhrasePrefix() {
        let completion = VocabularyCompletionMatcher.bestCompletion(
            for: "machine le",
            candidates: ["machine learning"]
        )

        XCTAssertEqual(
            completion,
            VocabularyCompletion(completedText: "machine learning", suffix: "arning")
        )
    }

    func testRejectsShortExactMultilineAndSubstringInputs() {
        XCTAssertNil(VocabularyCompletionMatcher.bestCompletion(for: "q", candidates: ["quick"]))
        XCTAssertNil(VocabularyCompletionMatcher.bestCompletion(for: "quick", candidates: ["quick"]))
        XCTAssertNil(VocabularyCompletionMatcher.bestCompletion(for: "qu\nick", candidates: ["quick"]))
        XCTAssertNil(VocabularyCompletionMatcher.bestCompletion(for: "ick", candidates: ["quick"]))
    }

    func testRejectsLeadingWhitespaceAndEmptyVocabulary() {
        XCTAssertNil(VocabularyCompletionMatcher.bestCompletion(for: " qu", candidates: ["quick"]))
        XCTAssertNil(VocabularyCompletionMatcher.bestCompletion(for: "qu", candidates: []))
    }
}
