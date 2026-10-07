import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteWriteGateTests: XCTestCase {
    func testBlocksEveryMutationBeforeChangingModels() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try WordNoteTestFixture.populated.populate(context)
        let before = try WordNoteSnapshotPayload.capture(from: context)
        let course = try XCTUnwrap(context.fetch(FetchDescriptor<CourseModel>()).first)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<InputRecordModel>()).first)
        let candidate = try XCTUnwrap(context.fetch(FetchDescriptor<CandidateTermModel>()).first)
        let term = try XCTUnwrap(context.fetch(FetchDescriptor<TermModel>()).first)
        let input = InputRecordService(modelContext: context)
        let vocabulary = VocabularyService(modelContext: context)
        let courses = CourseService(modelContext: context)
        let review = ReviewService(modelContext: context)
        let result = WordNoteTestFixture.analysisResult(for: request)
        let mutations: [() throws -> Void] = [
            { _ = try input.createDraft(rawText: "new", courseID: nil, sourceType: .other, note: nil) },
            { _ = try input.createAnalyzing(rawText: "new", courseID: nil, sourceType: .other, note: nil) },
            { try input.markAnalyzing(record) },
            { _ = try input.applyAnalysisResult(result, to: record) },
            { try input.markFailed(record, summary: "failure") },
            { try input.ignore(record) },
            { try input.delete(record) },
            { _ = try vocabulary.bumpDuplicateHit(term) },
            { _ = try vocabulary.confirmCandidates([.init(candidates: [candidate], sourceRecord: record)]) },
            { _ = try vocabulary.createManualTerm(termText: "new", chineseMeaning: "新", englishDefinition: nil, sourceRecord: record) },
            { try vocabulary.ignore([candidate], sourceRecord: record) },
            { try vocabulary.updateTerm(term, termText: "updated", termType: .word, chineseMeaning: "新", englishDefinition: nil, aiContextExplanation: nil, exampleSentence: nil, contextSentence: nil, courseID: nil, sourceType: .other, category: .general, importance: .medium, masteryLevel: .new) },
            { try vocabulary.delete(term) },
            { _ = try courses.create(courseName: "new", courseCode: nil, instructor: nil, semester: nil, description: nil) },
            { try courses.update(course, courseName: "new", courseCode: nil, instructor: nil, semester: nil, description: nil) },
            { try courses.delete(course) },
            { _ = try review.recordFeedback(for: term, feedback: .again) },
            { try review.postponeUntilTomorrow(term) },
            { _ = try DataIntegrityService(modelContext: context).repairDanglingReferences() }
        ]
        let lock = try WordNoteWriteGate.beginRestore(context)
        for mutate in mutations {
            XCTAssertThrowsError(try mutate()) { XCTAssertEqual($0 as? WordNoteWriteError, .restoreInProgress) }
        }
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: context), before)
        XCTAssertFalse(context.hasChanges)
        try WordNoteWriteGate.endRestore(context, ticket: lock)
    }

    func testSharedContainerContextsBlockedButIndependentStoreIsNot() throws {
        let first = try makeContainer()
        let second = try makeContainer()
        let otherWindow = ModelContext(first)
        let lock = try WordNoteWriteGate.beginRestore(first.mainContext)
        XCTAssertThrowsError(try WordNoteWriteGate.check(otherWindow))
        XCTAssertNoThrow(try WordNoteWriteGate.check(second.mainContext))
        XCTAssertThrowsError(try WordNoteWriteGate.beginRestore(otherWindow))
        try WordNoteWriteGate.endRestore(otherWindow, ticket: lock)
        XCTAssertNoThrow(try WordNoteWriteGate.check(first.mainContext))
        XCTAssertThrowsError(try WordNoteWriteGate.endRestore(first.mainContext, ticket: lock))
    }

    func testLateSuccessAndFailureCannotWriteAfterRestoreCancellation() async throws {
        for shouldFail in [false, true] {
            let container = try makeContainer()
            let context = container.mainContext
            let service = InputRecordService(modelContext: context)
            let record = try service.createDraft(rawText: "regularization", courseID: nil, sourceType: .other, note: nil)
            let pending = SuspendedAnalysis()
            let task = Task { try await service.analyze(record, request: request, using: pending.analyze) }
            await pending.waitForRequest()
            let lock = try WordNoteWriteGate.beginRestore(context)
            let before = try WordNoteSnapshotPayload.capture(from: context)
            try WordNoteWriteGate.endRestore(context, ticket: lock)
            pending.finish(failing: shouldFail)
            do { _ = try await task.value; XCTFail("Expected the old callback to expire.") }
            catch { XCTAssertEqual(error as? WordNoteWriteError, .expiredOperation) }
            XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: context), before)
        }
    }

    func testScheduledRequestWithExpiredTicketNeverCallsHandler() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let service = InputRecordService(modelContext: context)
        let record = try service.createDraft(rawText: "regularization", courseID: nil, sourceType: .other, note: nil)
        let ticket = try WordNoteWriteGate.ticket(for: context)
        let lock = try WordNoteWriteGate.beginRestore(context)
        try WordNoteWriteGate.endRestore(context, ticket: lock)
        var calls = 0
        do {
            try await service.analyze(record, request: request, ticket: ticket) { request in
                calls += 1
                return WordNoteTestFixture.analysisResult(for: request)
            }
            XCTFail("Expected the scheduled request to expire.")
        } catch { XCTAssertEqual(error as? WordNoteWriteError, .expiredOperation) }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(record.status, .draft)
    }

    func testQueueSuspensionBeforeWorkerStartsDoesNotIssueRequest() async throws {
        let container = try makeContainer()
        var calls = 0
        let queue = QuickAddAnalysisQueue(modelContext: container.mainContext) { request in
            calls += 1
            return WordNoteTestFixture.analysisResult(for: request)
        }
        try queue.enqueue(rawText: "regularization", courseID: nil, courseName: nil, sourceType: .other, note: nil)
        queue.suspendForRestore()
        await Task.yield()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try queue.recoverPendingAnalyses(), 0)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try queue.resumePendingAnalyses(), 1)
        try await queue.waitUntilIdle()
        XCTAssertEqual(calls, 1)
    }

    func testCancelledWorkerIgnoringCancellationDoesNotWriteOrReplaceNewStatus() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let pending = SuspendedAnalysis()
        let queue = QuickAddAnalysisQueue(modelContext: context, analysisHandler: pending.analyze)
        try queue.enqueue(rawText: "regularization", courseID: nil, courseName: nil, sourceType: .other, note: nil)
        await pending.waitForRequest()
        let lock = try WordNoteWriteGate.beginRestore(context)
        queue.suspendForRestore()
        let before = try WordNoteSnapshotPayload.capture(from: context)
        try WordNoteWriteGate.endRestore(context, ticket: lock)
        queue.statusMessage = "Restore was cancelled."
        pending.finish()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: context), before)
        XCTAssertEqual(queue.statusMessage, "Restore was cancelled.")
        XCTAssertNil(queue.latestAIExplanation)
    }

    private var request: AIAnalysisRequest {
        AIAnalysisRequest(rawText: "regularization", courseName: nil, sourceType: .other, userNote: nil)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }
}

@MainActor
final class SuspendedAnalysis {
    private var continuation: CheckedContinuation<AIAnalysisResult, Error>?
    private var request: AIAnalysisRequest?
    func analyze(_ request: AIAnalysisRequest) async throws -> AIAnalysisResult {
        self.request = request
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitForRequest() async {
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        XCTAssertNotNil(continuation)
    }
    func finish(failing: Bool = false) {
        guard let continuation, let request else { return XCTFail("No analysis request is waiting.") }
        self.continuation = nil
        if failing { continuation.resume(throwing: AIAnalysisError.timeout) }
        else { continuation.resume(returning: WordNoteTestFixture.analysisResult(for: request)) }
    }
}
