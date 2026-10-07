import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class EnglishSubjectBoundaryTests: XCTestCase {
    func testEnglishSourceCannotSaveChineseOrBlankCandidateAsTerm() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let record = InputRecordModel(rawText: "overfitting", status: .analyzed)
        context.insert(record)
        for text in ["過擬合", "overfitting 過擬合", "", "123"] {
            let candidate = CandidateTermModel(
                inputRecordID: record.id, term: text, termType: .word,
                needToLearn: true, importance: .high, category: .aiML, chineseMeaning: "過擬合"
            )
            context.insert(candidate)
            try context.save()
            XCTAssertThrowsError(try VocabularyService(modelContext: context).createTerms(from: [candidate], sourceRecord: record)) {
                XCTAssertEqual($0 as? VocabularyServiceError, .englishTermRequired(text))
            }
            XCTAssertEqual(candidate.status, .pending)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TermModel>()), 0)
        XCTAssertEqual(record.status, .analyzed)
    }

    func testManualEntryRejectsChineseSubjectForBothLookupDirections() throws {
        let container = try makeContainer()
        let context = container.mainContext
        for source in ["overfitting", "過擬合"] {
            let record = InputRecordModel(rawText: source)
            context.insert(record)
            try context.save()
            XCTAssertThrowsError(try VocabularyService(modelContext: context).createManualTerm(
                termText: "過擬合", chineseMeaning: "模型過度貼合訓練資料", englishDefinition: nil, sourceRecord: record
            )) {
                XCTAssertEqual($0 as? VocabularyServiceError, .englishTermRequired("過擬合"))
            }
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TermModel>()), 0)
    }

    func testEditingTermRejectsChineseBeforeMutatingAnyFields() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let term = TermModel(term: "quick", termType: .word, chineseMeaning: "迅速的")
        context.insert(term)
        try context.save()
        let updatedAt = term.updatedAt
        XCTAssertThrowsError(try update(term, to: "迅速的", context: context)) {
            XCTAssertEqual($0 as? VocabularyServiceError, .englishTermRequired("迅速的"))
        }
        XCTAssertEqual(term.term, "quick")
        XCTAssertEqual(term.chineseMeaning, "迅速的")
        XCTAssertEqual(term.updatedAt, updatedAt)
        XCTAssertFalse(context.hasChanges)
    }

    func testInvalidLegacyTermIsPreservedAndCanBeCorrected() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let term = TermModel(term: "迅速的", termType: .word, chineseMeaning: "迅速的")
        context.insert(term)
        try context.save()
        let id = term.id
        XCTAssertThrowsError(try update(term, to: "迅速的", context: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TermModel>()), 1)
        try update(term, to: "quick", context: context)
        XCTAssertEqual(term.id, id)
        XCTAssertEqual(term.term, "quick")
    }

    func testTechnicalEnglishTermsRemainValid() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let record = InputRecordModel(rawText: "Programming concepts")
        context.insert(record)
        try context.save()
        for text in ["C++", "L2", ".NET", "naïve Bayes", "out-of-distribution"] {
            let term = try VocabularyService(modelContext: context).createManualTerm(
                termText: text, chineseMeaning: "測試釋義", englishDefinition: nil, sourceRecord: record
            )
            XCTAssertEqual(term.term, text)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TermModel>()), 5)
    }

    private func update(_ term: TermModel, to text: String, context: ModelContext) throws {
        try VocabularyService(modelContext: context).updateTerm(
            term, termText: text, termType: .word,
            chineseMeaning: "更新的釋義", englishDefinition: nil,
            aiContextExplanation: nil, exampleSentence: nil, contextSentence: nil,
            courseID: nil, sourceType: .other, category: .general, importance: .medium, masteryLevel: .new
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        ])
    }
}
