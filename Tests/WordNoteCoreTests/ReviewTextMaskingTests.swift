import XCTest
@testable import WordNoteCore

final class ReviewTextMaskingTests: XCTestCase {
    func testWholeWordBoundariesDoNotHideSubstringsOrTechnicalIdentifiers() throws {
        XCTAssertEqual(try ReviewTextMasking.mask("A quick test is quicker; QUICK. quick_sort quick-test", forms: ["quick"]),
                       "A ____ test is quicker; ____. quick_sort quick-test")
    }

    func testTechnicalPunctuationIsLiteralAndBoundaryAware() throws {
        XCTAssertEqual(try ReviewTextMasking.mask("C++ and C# differ from C, C+++ and C#value.", forms: ["C++", "C#"]),
                       "____ and ____ differ from C, C+++ and C#value.")
        XCTAssertEqual(try ReviewTextMasking.mask("Use a.b, not axb or a*b.", forms: ["a.b", "a*b"]), "Use ____, not axb or ____.")
    }

    func testWhitespaceHyphensAndApostrophesUseExplicitVariants() throws {
        let source = "State-of-the-art and state\u{2011}of\u{2011}the\u{2011}art aren't new; aren\u{2019}t old. all\n sorts\t of."
        XCTAssertEqual(try ReviewTextMasking.mask(source, forms: ["state-of-the-art", "aren't", "all sorts of"]),
                       "____ and ____ ____ new; ____ old. ____.")
    }

    func testGraphemeOffsetsSurviveEmojiAndCanonicalEquivalence() throws {
        let source = "👩🏽‍💻 cafe\u{301} and CAFÉ."
        let ranges = try ReviewTextMasking.ranges(in: source, forms: ["café"])
        XCTAssertEqual(ranges, [.init(start: 2, count: 4), .init(start: 11, count: 4)])
        XCTAssertEqual(try ranges[0].text(in: source), "cafe\u{301}")
        XCTAssertEqual(try ReviewTextMasking.mask(source, ranges: ranges), "👩🏽‍💻 ____ and ____.")
    }

    func testEnglishHeadwordEmbeddedInChineseIsHidden() throws {
        XCTAssertEqual(try ReviewTextMasking.mask("RGB色彩模型；以RGB表示颜色", forms: ["RGB"]), "____色彩模型；以____表示颜色")
    }

    func testQuotesAreNotConfusedWithApostrophesInsideWords() throws {
        XCTAssertEqual(try ReviewTextMasking.mask("'quick' and ‘quick’ are not quick's or un'quick.", forms: ["quick"]),
                       "'____' and ‘____’ are not quick's or un'quick.")
    }

    func testOverlappingRangesMergeAndAdjacentRangesRemainSeparate() throws {
        XCTAssertEqual(try ReviewTextMasking.mask("all sorts of things", forms: ["all sorts", "sorts of", "all sorts of"]), "____ things")
        XCTAssertEqual(try ReviewTextMasking.mask("abcd", ranges: [.init(start: 0, count: 2), .init(start: 2, count: 2)]), "________")
    }

    func testInvalidExtremeAndEmptyRangesThrowWithoutArithmeticTrap() throws {
        for range in [ReviewTextRange(start: -1, count: 1), .init(start: 0, count: 0), .init(start: Int.max, count: Int.max),
                      .init(start: 1, count: Int.min), .init(start: 4, count: 1)] {
            XCTAssertThrowsError(try ReviewTextMasking.mask("abc", ranges: [range]))
        }
        XCTAssertEqual(try ReviewTextMasking.mask("", ranges: []), "")
    }

    func testMatchCountAndFormCountAreBounded() throws {
        XCTAssertThrowsError(try ReviewTextMasking.ranges(in: String(repeating: "a ", count: 1_001), forms: ["a"])) {
            XCTAssertEqual($0 as? ReviewQuestionError, .tooManyMatches)
        }
        XCTAssertThrowsError(try ReviewTextMasking.ranges(in: "a", forms: Array(repeating: "a", count: 103)))
    }

    func testManyUnicodeMatchesUseOriginalCharacterBoundaries() throws {
        let segment = "👩🏽‍💻 cafe\u{301} and "
        let source = String(repeating: segment, count: 900)
        let ranges = try ReviewTextMasking.ranges(in: source, forms: ["café"])
        XCTAssertEqual(ranges.count, 900)
        XCTAssertEqual(ranges.last, .init(start: 899 * segment.count + 2, count: 4))
        XCTAssertEqual(try ReviewTextMasking.mask(source, ranges: ranges), String(repeating: "👩🏽‍💻 ____ and ", count: 900))
    }

    func testClozeHidesAllOccurrencesAndOnlyExplicitInflections() throws {
        let source = "She manipulates data and can manipulate it; data was manipulated yesterday."
        XCTAssertEqual(try ReviewClozeBuilder.suggestedRanges(term: "manipulate", source: source).count, 1)
        let selected = try XCTUnwrap(ReviewTextMasking.ranges(in: source, forms: ["manipulates"]).first)
        let preview = try ReviewClozeBuilder.preview(occurrenceID: UUID(), source: source, term: "manipulate",
            selectedRange: selected, acceptedAnswers: ["manipulated"])
        XCTAssertEqual(preview.target.answer, "manipulates")
        XCTAssertEqual(preview.prompt, "She ____ data and can ____ it; data was ____ yesterday.")
        XCTAssertEqual(preview.hiddenRanges.count, 3)
    }

    func testClozeRejectsHeadwordOnlyChineseSourceAndPartialSelection() throws {
        for source in ["quick", "quick quick", "quick，快速"] {
            XCTAssertThrowsError(try ReviewClozeBuilder.preview(occurrenceID: UUID(), source: source, term: "quick",
                selectedRange: .init(start: 0, count: 5)))
        }
        XCTAssertThrowsError(try ReviewClozeBuilder.preview(occurrenceID: UUID(), source: "A quicker way.", term: "quick",
            selectedRange: .init(start: 2, count: 5)))
    }

    func testRawSourceHashRejectsEvenCanonicallyEquivalentEdits() throws {
        let source = "A café serves coffee."
        let preview = try ReviewClozeBuilder.preview(occurrenceID: UUID(), source: source, term: "café",
            selectedRange: .init(start: 2, count: 4))
        XCTAssertThrowsError(try ReviewClozeBuilder.render(target: preview.target, term: "café", source: "A cafe\u{301} serves coffee.")) {
            XCTAssertEqual($0 as? ReviewQuestionError, .sourceChanged)
        }
    }

    func testTypedAnswerNormalizationNeverGradesAnUnknownSynonymAsFailure() {
        XCTAssertEqual(ReviewQuestionContent.assess("  CAFE\u{301}  ", acceptedAnswers: ["café"]), .matchesSavedAnswer)
        XCTAssertEqual(ReviewQuestionContent.assess("all \n sorts\t of", acceptedAnswers: ["all sorts of"]), .matchesSavedAnswer)
        XCTAssertEqual(ReviewQuestionContent.assess("fast", acceptedAnswers: ["quick"]), .needsSelfAssessment)
        XCTAssertEqual(ReviewQuestionContent.assess("", acceptedAnswers: ["quick"]), .empty)
    }
}
