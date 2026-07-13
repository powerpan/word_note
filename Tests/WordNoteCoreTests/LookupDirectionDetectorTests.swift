import XCTest
@testable import WordNoteCore

final class LookupDirectionDetectorTests: XCTestCase {
    func testChineseInputUsesChineseToEnglish() {
        XCTAssertEqual(LookupDirectionDetector.detect("過擬合"), .chineseToEnglish)
        XCTAssertEqual(LookupDirectionDetector.detect("神经网络"), .chineseToEnglish)
    }

    func testEnglishInputUsesEnglishToChinese() {
        XCTAssertEqual(LookupDirectionDetector.detect("gradient descent"), .englishToChinese)
        XCTAssertEqual(LookupDirectionDetector.detect("Transformer 是什麼"), .englishToChinese)
    }

    func testChineseDominantMixedInputUsesChineseToEnglish() {
        XCTAssertEqual(
            LookupDirectionDetector.detect("AI 模型如何避免過擬合"),
            .chineseToEnglish
        )
    }

    func testEnglishVocabularyTermRequiresLatinAndRejectsHan() {
        XCTAssertTrue(LookupDirectionDetector.isEnglishVocabularyTerm("L2 regularization"))
        XCTAssertFalse(LookupDirectionDetector.isEnglishVocabularyTerm("過擬合"))
        XCTAssertFalse(LookupDirectionDetector.isEnglishVocabularyTerm("overfitting（過擬合）"))
    }
}
