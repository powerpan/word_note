import XCTest
@testable import WordNoteCore

@MainActor
final class VocabularyReadingContentTests: XCTestCase {
    private typealias Values = VocabularyTestValues

    func testReadSectionsKeepEveryMeaningAndExampleWithoutTruncation() {
        var term = Values.term("stage", chinese: String(repeating: "階段；舞台；期別\n", count: 40), english: "  First\nSecond  ")
        term.aiContextExplanation = "A step in a processing pipeline."
        term.exampleSentence = "We reached the final stage."
        let content = VocabularyReadingContent(term: term, occurrences: [])
        XCTAssertEqual(content.meanings.map(\.id), ["chinese", "english", "technical", "example"])
        XCTAssertEqual(content.meanings.map(\.text), [term.chineseMeaning, term.englishDefinition, term.aiContextExplanation, term.exampleSentence].compactMap { $0 })
    }

    func testBlankSectionsAreOmittedWithoutInventingDefinitionsOrSources() {
        var term = Values.term("quick", chinese: "\n \t", english: nil)
        term.aiContextExplanation = ""
        term.contextSentence = " "
        let content = VocabularyReadingContent(term: term, occurrences: [])
        XCTAssertTrue(content.meanings.isEmpty)
        XCTAssertTrue(content.sources.isEmpty)
        XCTAssertNil(content.source)
    }

    func testOriginalSourceIsPreferredAndMutableContextRemainsSeparate() {
        var term = Values.term("quick")
        let originalID = UUID()
        term.sourceRecordID = originalID
        term.contextSentence = "Manually revised context"
        let original = Values.occurrence(term.id, sourceID: originalID, text: "Original input", note: "Lecture note",
                                         at: Values.now.addingTimeInterval(-10))
        let recent = Values.occurrence(term.id, sourceID: UUID(), text: "Recent repeat input")
        let unrelated = Values.occurrence(UUID(), sourceID: originalID, text: "Must never leak into this term")
        let content = VocabularyReadingContent(term: term, occurrences: [recent, unrelated, original])
        XCTAssertEqual(content.source?.id, original.id)
        XCTAssertEqual(content.sources.map(\.title), ["Captured Input", "Source Note", "Saved Context"])
        XCTAssertEqual(content.sources.map(\.text), ["Original input", "Lecture note", "Manually revised context"])
    }

    func testMissingOriginalUsesTruthfullyLabeledLatestSourceAndAvoidsDuplicateContext() {
        var term = Values.term("quick")
        term.sourceRecordID = UUID()
        term.contextSentence = "Latest input"
        let latest = Values.occurrence(term.id, text: "Latest input")
        let older = Values.occurrence(term.id, text: "Older input", at: Values.now.addingTimeInterval(-1))
        let content = VocabularyReadingContent(term: term, occurrences: [older, latest])
        XCTAssertEqual(content.source?.id, latest.id)
        XCTAssertEqual(content.sources.map(\.title), ["Latest Captured Input"])
        XCTAssertEqual(content.sources.map(\.text), ["Latest input"])
    }

    func testLegacySavedContextIsNotMisrepresentedAsCapturedInput() {
        var term = Values.term("quick")
        term.contextSentence = "Legacy context"
        let content = VocabularyReadingContent(term: term, occurrences: [])
        XCTAssertNil(content.source)
        XCTAssertEqual(content.sources.map(\.title), ["Saved Context"])
        XCTAssertEqual(content.sources.map(\.text), ["Legacy context"])
    }
}
