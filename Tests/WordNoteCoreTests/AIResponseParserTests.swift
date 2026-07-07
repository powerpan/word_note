import XCTest
@testable import WordNoteCore

final class AIResponseParserTests: XCTestCase {
    func testParsesStructuredJSONAndMapsEnums() throws {
        let json = """
        {
          "input_type": "sentence",
          "sentence_meaning": "模型會從輸入資料中學習一種隱含表示。",
          "items": [
            {
              "term": "latent representation",
              "term_type": "phrase",
              "need_to_learn": true,
              "importance": "high",
              "category": "AI/ML",
              "reason": "Core representation learning concept.",
              "chinese_meaning": "隱含表示",
              "english_definition": "An internal feature representation learned by a model.",
              "ai_context_explanation": "Common in representation learning and neural networks.",
              "example_sentence": "The encoder maps inputs into a latent representation.",
              "related_terms": ["encoder", "embedding"],
              "confidence": 0.96,
              "should_auto_select": true
            }
          ]
        }
        """

        let result = try AIResponseParser().parse(content: json, model: "deepseek-v4-flash", responseID: "abc")

        XCTAssertEqual(result.inputType, .sentence)
        XCTAssertEqual(result.sentenceMeaning, "模型會從輸入資料中學習一種隱含表示。")
        XCTAssertEqual(result.model, "deepseek-v4-flash")
        XCTAssertEqual(result.rawResponseID, "abc")
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.term, "latent representation")
        XCTAssertEqual(result.candidates.first?.termType, .phrase)
        XCTAssertEqual(result.candidates.first?.importance, .high)
        XCTAssertEqual(result.candidates.first?.category, .aiML)
        XCTAssertEqual(result.candidates.first?.shouldAutoSelect, true)
    }

    func testStripsMarkdownFenceAndDropsDuplicateTerms() throws {
        let fenced = """
        ```json
        {
          "input_type": "phrase",
          "sentence_meaning": "",
          "items": [
            {"term": "Gradient Descent", "term_type": "phrase", "need_to_learn": true, "importance": "high", "category": "AI/ML"},
            {"term": "gradient   descent", "term_type": "phrase", "need_to_learn": true, "importance": "medium", "category": "AI/ML"}
          ]
        }
        ```
        """

        let result = try AIResponseParser().parse(content: fenced, model: "test", responseID: nil)

        XCTAssertEqual(result.inputType, .phrase)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.term, "Gradient Descent")
    }

    func testThrowsSchemaMismatchForInvalidJSON() {
        XCTAssertThrowsError(
            try AIResponseParser().parse(content: "not json", model: "test", responseID: nil)
        ) { error in
            guard case AIAnalysisError.schemaMismatch = error else {
                return XCTFail("Expected schema mismatch, got \(error)")
            }
        }
    }
}
