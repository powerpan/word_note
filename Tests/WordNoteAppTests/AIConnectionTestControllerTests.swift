import XCTest
import WordNoteCore
@testable import WordNote

@MainActor
final class AIConnectionTestControllerTests: XCTestCase {
    func testNoAutomaticRequestAndExplicitTestRecordsCompletionTime() async throws {
        var calls = 0
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let controller = AIConnectionTestController(now: { date }) { calls += 1; return "test-model" }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(controller.state, .idle)
        let task = try XCTUnwrap(controller.start())
        XCTAssertEqual(controller.state, .running)
        await task.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(controller.state, .succeeded(.init(model: "test-model", completedAt: date)))
        controller.cancel()
        XCTAssertEqual(controller.state, .succeeded(.init(model: "test-model", completedAt: date)))
    }

    func testDoubleClickIsSingleFlightAndCancelledLateSuccessCannotOverwriteNewAttempt() async throws {
        var callbacks: [CheckedContinuation<String, Error>] = []
        let controller = AIConnectionTestController {
            try await withCheckedThrowingContinuation { callbacks.append($0) }
        }
        defer { callbacks.forEach { $0.resume(throwing: CancellationError()) } }
        let first = try XCTUnwrap(controller.start())
        XCTAssertNil(controller.start())
        try await waitUntil { callbacks.count == 1 }
        controller.cancel()
        XCTAssertEqual(controller.state, .cancelled)
        let second = try XCTUnwrap(controller.start())
        try await waitUntil { callbacks.count == 2 }
        callbacks.removeLast().resume(returning: "new-model")
        await second.value
        let current = controller.state
        callbacks.removeFirst().resume(returning: "stale-model")
        await first.value
        XCTAssertEqual(controller.state, current)
        guard case .succeeded(let value) = current else { return XCTFail("Expected new success") }
        XCTAssertEqual(value.model, "new-model")
    }

    func testChangingCredentialsInvalidatesPendingResultAndClearsStatus() async throws {
        var callback: CheckedContinuation<String, Error>?
        let controller = AIConnectionTestController { try await withCheckedThrowingContinuation { callback = $0 } }
        defer { callback?.resume(throwing: CancellationError()) }
        let task = try XCTUnwrap(controller.start())
        try await waitUntil { callback != nil }
        controller.credentialsChanged()
        callback?.resume(throwing: AIAnalysisError.network("private-detail"))
        callback = nil
        await task.value
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.retryNotBefore)
    }

    func testCancelBeforeScheduledTaskBeginsDoesNotInvokeProvider() async throws {
        var calls = 0
        let controller = AIConnectionTestController { calls += 1; return "test-model" }
        let task = try XCTUnwrap(controller.start())
        controller.cancel()
        await task.value
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(controller.state, .cancelled)
    }

    func testProviderErrorsAreRedactedAndNeverAutomaticallyRetried() async throws {
        for failure in [AIAnalysisError.missingAPIKey, .timeout, .network("private-detail"),
                        .server(statusCode: 401, summary: "private-detail"), .server(statusCode: 500, summary: "private-detail"),
                        .schemaMismatch("private-detail")] {
            var calls = 0
            let controller = AIConnectionTestController { calls += 1; throw failure }
            try await XCTUnwrap(controller.start()).value
            XCTAssertEqual(calls, 1)
            guard case .failed(let message) = controller.state else { return XCTFail("Expected failure") }
            XCTAssertFalse(message.contains("private-detail"))
            XCTAssertNil(controller.retryNotBefore)
        }
    }

    func testRetryAfterBlocksManualClickUntilDeadlineWithoutSchedulingNetwork() async throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000), calls = 0
        let deadline = now.addingTimeInterval(120)
        let controller = AIConnectionTestController(now: { now }) {
            calls += 1
            throw AIAnalysisRetryAfterError(failure: .rateLimited, notBefore: deadline)
        }
        try await XCTUnwrap(controller.start()).value
        XCTAssertEqual(controller.retryNotBefore, deadline)
        XCTAssertNil(controller.start())
        now = deadline.addingTimeInterval(-1)
        XCTAssertFalse(controller.canStart(at: now))
        now = deadline
        XCTAssertTrue(controller.canStart(at: now))
        XCTAssertEqual(calls, 1)
        try await XCTUnwrap(controller.start()).value
        XCTAssertEqual(calls, 2)
    }

    func testProviderCancellationAndUnknownFailuresUseSafeStatuses() async throws {
        let cancelled = AIConnectionTestController { throw CancellationError() }
        try await XCTUnwrap(cancelled.start()).value
        XCTAssertEqual(cancelled.state, .cancelled)
        let unknown = AIConnectionTestController { throw NSError(domain: "private-detail", code: 1) }
        try await XCTUnwrap(unknown.start()).value
        guard case .failed(let message) = unknown.state else { return XCTFail("Expected failure") }
        XCTAssertFalse(message.contains("private-detail"))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "Connection test task did not start", code: 1) }
            await Task.yield()
        }
    }
}
