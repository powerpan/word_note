import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class InputRecordServiceTests: XCTestCase {
    func testCreateDraftPersistsTrimmedRecord() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let courseID = UUID()
        let service = InputRecordService(modelContext: context)

        let record = try service.createDraft(
            rawText: "  latent representation  ",
            courseID: courseID,
            sourceType: .paper,
            note: "  VAE lecture  "
        )

        XCTAssertEqual(record.rawText, "latent representation")
        XCTAssertEqual(record.normalizedText, "latent representation")
        XCTAssertEqual(record.courseID, courseID)
        XCTAssertEqual(record.sourceType, .paper)
        XCTAssertEqual(record.note, "VAE lecture")
        XCTAssertEqual(record.status, .draft)

        let records = try context.fetch(FetchDescriptor<InputRecordModel>())
        XCTAssertEqual(records.count, 1)
    }

    func testCreateDraftRejectsBlankRawText() throws {
        let context = ModelContext(try makeInMemoryContainer())
        let service = InputRecordService(modelContext: context)

        XCTAssertThrowsError(
            try service.createDraft(rawText: " \n ", courseID: nil, sourceType: .other, note: nil)
        ) { error in
            XCTAssertEqual(error as? InputRecordValidationError, .blankRawText)
        }
    }

    func testIgnoreAndDeletePersistChanges() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let service = InputRecordService(modelContext: context)
        let record = try service.createDraft(
            rawText: "gradient descent",
            courseID: nil,
            sourceType: .class,
            note: nil
        )

        try service.ignore(record)
        XCTAssertEqual(record.status, .ignored)

        try service.delete(record)
        let records = try context.fetch(FetchDescriptor<InputRecordModel>())
        XCTAssertTrue(records.isEmpty)
    }

    func testApplyAnalysisResultPersistsCandidatesAndMarksAnalyzed() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let service = InputRecordService(modelContext: context)
        let record = try service.createAnalyzing(
            rawText: "The model learns a latent representation.",
            courseID: nil,
            sourceType: .slides,
            note: nil
        )
        let result = AIAnalysisResult(
            inputType: .sentence,
            sentenceMeaning: "模型學習一種隱含表示。",
            candidates: [
                AIAnalysisCandidate(
                    term: "latent representation",
                    termType: .phrase,
                    needToLearn: true,
                    importance: .high,
                    category: .aiML,
                    chineseMeaning: "隱含表示"
                )
            ],
            model: "test-model",
            rawResponseID: "response-1"
        )

        let candidates = try service.applyAnalysisResult(result, to: record)

        XCTAssertEqual(record.status, .analyzed)
        XCTAssertEqual(record.inputType, .sentence)
        XCTAssertEqual(record.sentenceMeaning, "模型學習一種隱含表示。")
        XCTAssertEqual(candidates.count, 1)

        let persistedCandidates = try context.fetch(FetchDescriptor<CandidateTermModel>())
        XCTAssertEqual(persistedCandidates.map(\.normalizedTerm), ["latent representation"])
        XCTAssertEqual(persistedCandidates.first?.inputRecordID, record.id)
    }

    func testReanalysisReplacesPendingCandidatesAndKeepsSavedHistory() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let service = InputRecordService(modelContext: context)
        let record = try service.createAnalyzing(
            rawText: "A model uses regularization.",
            courseID: nil,
            sourceType: .paper,
            note: nil
        )
        let saved = CandidateTermModel(
            inputRecordID: record.id,
            term: "model",
            termType: .word,
            needToLearn: true,
            importance: .medium,
            category: .aiML,
            chineseMeaning: "模型",
            status: .saved
        )
        let stale = CandidateTermModel(
            inputRecordID: record.id,
            term: "stale",
            termType: .word,
            needToLearn: true,
            importance: .low,
            category: .general,
            chineseMeaning: "舊候選"
        )
        context.insert(saved)
        context.insert(stale)
        try context.save()

        let result = AIAnalysisResult(
            inputType: .sentence,
            sentenceMeaning: "模型使用正則化。",
            candidates: [
                AIAnalysisCandidate(
                    term: "model",
                    termType: .word,
                    needToLearn: true,
                    importance: .medium,
                    category: .aiML,
                    chineseMeaning: "模型"
                ),
                AIAnalysisCandidate(
                    term: "regularization",
                    termType: .word,
                    needToLearn: true,
                    importance: .high,
                    category: .aiML,
                    chineseMeaning: "正則化"
                )
            ],
            model: "test-model",
            rawResponseID: nil
        )

        let newCandidates = try service.applyAnalysisResult(result, to: record)
        let persistedCandidates = try context.fetch(FetchDescriptor<CandidateTermModel>())

        XCTAssertEqual(newCandidates.map(\.normalizedTerm), ["regularization"])
        XCTAssertEqual(Set(persistedCandidates.map(\.normalizedTerm)), ["model", "regularization"])
        XCTAssertEqual(persistedCandidates.first { $0.normalizedTerm == "model" }?.status, .saved)
    }

    func testDeleteRecordCascadesCandidatesAndClearsTermSourceReference() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let service = InputRecordService(modelContext: context)
        let record = try service.createDraft(
            rawText: "gradient descent",
            courseID: nil,
            sourceType: .class,
            note: nil
        )
        let candidate = CandidateTermModel(
            inputRecordID: record.id,
            term: "gradient descent",
            termType: .phrase,
            needToLearn: true,
            importance: .high,
            category: .aiML,
            chineseMeaning: "梯度下降"
        )
        let term = TermModel(
            term: "gradient descent",
            termType: .phrase,
            chineseMeaning: "梯度下降",
            sourceRecordID: record.id
        )
        context.insert(candidate)
        context.insert(term)
        try context.save()

        try service.delete(record)

        XCTAssertTrue(try context.fetch(FetchDescriptor<InputRecordModel>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CandidateTermModel>()).isEmpty)
        XCTAssertNil(term.sourceRecordID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TermModel>()).count, 1)
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            CourseModel.self,
            InputRecordModel.self,
            CandidateTermModel.self,
            TermModel.self,
            ReviewEventModel.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
