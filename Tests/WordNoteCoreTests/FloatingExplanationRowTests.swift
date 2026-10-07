import XCTest
@testable import WordNoteCore

final class FloatingExplanationRowTests: XCTestCase {
    func testChineseSingleCandidateUsesEnglishAnswerNotChineseQuery() {
        let rows = preview(rawText: "過擬合", terms: ["overfitting"]).floatingRows
        XCTAssertEqual(rows.map(\.source), ["overfitting"])
        XCTAssertEqual(rows.first?.meaning, "中文釋義")
    }

    func testEnglishSingleCandidateKeepsOriginalInputSpelling() {
        XCTAssertEqual(preview(rawText: "QUICK", terms: ["quick"]).floatingRows.first?.source, "QUICK")
    }

    func testMultipleCandidatesUseTheirOwnEnglishTerms() {
        XCTAssertEqual(
            preview(rawText: "迅速的", terms: ["quick", "rapid"]).floatingRows.map(\.source),
            ["quick", "rapid"]
        )
    }

    func testEnglishSentenceShowsWholeSentenceAndExtractedTerm() {
        let rows = preview(
            rawText: "She gave a quick response.", sentenceMeaning: "她迅速作出回應。", terms: ["quick"]
        ).floatingRows
        XCTAssertEqual(rows.map(\.source), ["She gave a quick response.", "quick"])
        XCTAssertEqual(rows.first?.meaning, "她迅速作出回應。")
    }

    func testChineseSentencePutsEnglishTranslationFirst() {
        let rows = preview(
            rawText: "她迅速作出回應。", sentenceMeaning: "She gave a quick response.", terms: ["quick"]
        ).floatingRows
        XCTAssertEqual(rows.map(\.source), ["She gave a quick response.", "quick"])
        XCTAssertEqual(rows.first?.meaning, "她迅速作出回應。")
    }

    func testInvalidChineseSentenceTranslationDoesNotHideEnglishCandidate() {
        let rows = preview(rawText: "迅速作出回應", sentenceMeaning: "中文不是英文答案", terms: ["respond quickly"]).floatingRows
        XCTAssertEqual(rows.map(\.source), ["respond quickly"])
    }

    func testEmptyResponseShowsExplicitPlaceholder() {
        let rows = preview(rawText: "query", terms: []).floatingRows
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isMuted)
        XCTAssertFalse(rows[0].meaning.isEmpty)
    }

    func testMissingChineseMeaningStillShowsEnglishAnswer() {
        let candidate = AIAnalysisCandidate(
            term: "overfitting", termType: .word, needToLearn: true, importance: .high, category: .aiML
        )
        let rows = AIExplanationPreview(
            rawText: "過擬合", sentenceMeaning: nil,
            candidates: [AIExplanationCandidatePreview(candidate: candidate)]
        ).floatingRows
        XCTAssertEqual(rows.first?.source, "overfitting")
        XCTAssertEqual(rows.first?.isMuted, true)
    }

    func testLongMeaningIsNotTruncatedAndRepeatedCandidatesHaveDistinctIDs() {
        let meaning = String(repeating: "長釋義。", count: 100)
        let rows = preview(rawText: "示例", terms: ["example", "example"], meaning: meaning).floatingRows
        XCTAssertEqual(rows.map(\.meaning), [meaning, meaning])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
    }

    private func preview(
        rawText: String, sentenceMeaning: String? = nil,
        terms: [String], meaning: String = "中文釋義"
    ) -> AIExplanationPreview {
        AIExplanationPreview(
            rawText: rawText, sentenceMeaning: sentenceMeaning,
            candidates: terms.map {
                AIExplanationCandidatePreview(candidate: AIAnalysisCandidate(
                    term: $0, termType: .word, needToLearn: true, importance: .medium,
                    category: .general, chineseMeaning: meaning,
                    exampleSentence: "This example must not be displayed in the floating preview."
                ))
            }
        )
    }
}
