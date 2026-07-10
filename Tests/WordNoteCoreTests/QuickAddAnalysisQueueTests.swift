import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class QuickAddAnalysisQueueTests: XCTestCase {
    func testRepeatedInputWhileAnalyzingReusesPersistedQueueRecord() async throws {
        let context = ModelContext(try makeInMemoryContainer())
        var analysisCallCount = 0
        let queue = QuickAddAnalysisQueue(modelContext: context) { request in
            analysisCallCount += 1
            try await Task.sleep(nanoseconds: 30_000_000)
            return Self.result(for: request.rawText)
        }

        let firstResult = try queue.enqueue(
            rawText: "  Regularization ",
            courseID: nil,
            courseName: nil,
            sourceType: .paper,
            note: nil
        )
        let secondResult = try queue.enqueue(
            rawText: "regularization",
            courseID: nil,
            courseName: nil,
            sourceType: .paper,
            note: nil
        )

        guard case .queued = firstResult else {
            return XCTFail("Expected the first request to be queued.")
        }
        guard case .alreadyQueued = secondResult else {
            return XCTFail("Expected the repeated request to reuse the queued record.")
        }

        try await queue.waitUntilIdle()

        let records = try context.fetch(FetchDescriptor<InputRecordModel>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.status, .analyzed)
        XCTAssertEqual(analysisCallCount, 1)
    }

    func testRecoverPendingAnalysesProcessesPersistedAnalyzingRecords() async throws {
        let context = ModelContext(try makeInMemoryContainer())
        let inputService = InputRecordService(modelContext: context)
        let record = try inputService.createAnalyzing(
            rawText: "latent representation",
            courseID: nil,
            sourceType: .slides,
            note: nil
        )
        let queue = QuickAddAnalysisQueue(modelContext: context) { request in
            Self.result(for: request.rawText)
        }

        XCTAssertEqual(try queue.recoverPendingAnalyses(), 1)
        try await queue.waitUntilIdle()

        XCTAssertEqual(record.status, .analyzed)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<CandidateTermModel>()).map(\.normalizedTerm),
            ["latent representation"]
        )
    }

    func testAnalysisFailurePersistsFailedRecordAndContinuesQueue() async throws {
        let context = ModelContext(try makeInMemoryContainer())
        var callCount = 0
        let queue = QuickAddAnalysisQueue(modelContext: context) { request in
            callCount += 1
            if request.rawText == "first" {
                throw AIAnalysisError.timeout
            }
            return Self.result(for: request.rawText)
        }

        try queue.enqueue(rawText: "first", courseID: nil, courseName: nil, sourceType: .other, note: nil)
        try queue.enqueue(rawText: "second", courseID: nil, courseName: nil, sourceType: .other, note: nil)
        try await queue.waitUntilIdle()

        let records = try context.fetch(FetchDescriptor<InputRecordModel>())
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(records.first { $0.rawText == "first" }?.status, .failed)
        XCTAssertEqual(records.first { $0.rawText == "second" }?.status, .analyzed)
    }

    func testExactVocabularyHitSkipsAnalysisAndInboxCreation() throws {
        let context = ModelContext(try makeInMemoryContainer())
        let term = TermModel(
            term: "regularization",
            termType: .word,
            chineseMeaning: "正則化"
        )
        context.insert(term)
        try context.save()
        var analysisCallCount = 0
        let queue = QuickAddAnalysisQueue(modelContext: context) { request in
            analysisCallCount += 1
            return Self.result(for: request.rawText)
        }

        let result = try queue.enqueue(
            rawText: " Regularization ",
            courseID: nil,
            courseName: nil,
            sourceType: .paper,
            note: nil
        )

        guard case .duplicateHit(let matchedTerm) = result else {
            return XCTFail("Expected an exact vocabulary hit.")
        }
        XCTAssertEqual(matchedTerm.id, term.id)
        XCTAssertEqual(analysisCallCount, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<InputRecordModel>()).isEmpty)
    }

    private static func result(for rawText: String) -> AIAnalysisResult {
        AIAnalysisResult(
            inputType: rawText.contains(" ") ? .phrase : .word,
            sentenceMeaning: nil,
            candidates: [
                AIAnalysisCandidate(
                    term: rawText,
                    termType: rawText.contains(" ") ? .phrase : .word,
                    needToLearn: true,
                    importance: .medium,
                    category: .general,
                    chineseMeaning: "測試釋義"
                )
            ],
            model: "test-model",
            rawResponseID: nil
        )
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(WordNoteSchemaV1.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
