import XCTest
@testable import WordNoteCore

final class VocabularySearchMatcherTests: XCTestCase {
    func testBlankQueryMatchesEveryTerm() {
        XCTAssertTrue(matches(query: "  \n"))
    }

    func testMatchesEnglishTermCaseInsensitively() {
        XCTAssertTrue(matches(query: "  GRADIENT  ", term: "gradient descent"))
    }

    func testMatchesEnglishDefinition() {
        XCTAssertTrue(
            matches(
                query: "optimization method",
                englishDefinition: "An iterative optimization method for neural networks."
            )
        )
    }

    func testSimplifiedQueryMatchesTraditionalChineseMeaning() {
        XCTAssertTrue(matches(query: "处理", chineseMeaning: "操縱；處理"))
    }

    func testTraditionalQueryMatchesSimplifiedChineseMeaning() {
        XCTAssertTrue(matches(query: "神經網絡", chineseMeaning: "用于训练神经网络的算法"))
    }

    func testChineseSearchIgnoresPunctuationAndWhitespace() {
        XCTAssertTrue(matches(query: "率 ； 比", chineseMeaning: "比率；比例"))
    }

    func testRejectsUnrelatedAndPunctuationOnlyQueries() {
        XCTAssertFalse(matches(query: "卷积", chineseMeaning: "比率；比例"))
        XCTAssertFalse(matches(query: "；", chineseMeaning: "比率；比例"))
    }

    private func matches(
        query: String,
        term: String = "gradient descent",
        chineseMeaning: String? = "梯度下降",
        englishDefinition: String? = nil
    ) -> Bool {
        VocabularySearchMatcher.matches(
            query: query,
            term: term,
            chineseMeaning: chineseMeaning,
            englishDefinition: englishDefinition
        )
    }
}
