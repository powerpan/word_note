import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3PerformanceTests: XCTestCase {
    func testDiskCaptureAndReviewPerformance() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_V3_PERFORMANCE_TESTS"] == "1" else {
            throw XCTSkip("Opt in with RUN_V3_PERFORMANCE_TESTS=1 and swift test -c release.")
        }
        #if DEBUG
        throw XCTSkip("V3 service performance evidence requires a Release build.")
        #else
        let iterations = Int(environment["V3_PERFORMANCE_ITERATIONS"] ?? "30") ?? 30
        let sizes = environment["V3_PERFORMANCE_SIZE"].flatMap(Int.init).map { [$0] } ?? [1_000, 10_000]
        XCTAssertTrue((1...100).contains(iterations))
        XCTAssertTrue(sizes.allSatisfy { [1_000, 10_000].contains($0) })
        guard (1...100).contains(iterations), sizes.allSatisfy({ [1_000, 10_000].contains($0) }) else { return }
        let root = try V3TestSupport.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = V3TestSupport.date.addingTimeInterval(86_400)

        for size in sizes {
            var payload = try WordNoteV2ToV3Migration.convert(
                WordNoteV1ToV2Migration.convert(WordNotePerformanceFixtures.v1(termCount: size)).payload, at: now
            )
            for index in payload.cards.indices {
                payload.cards[index].mode = .englishToChinese
                payload.cards[index].schedule.nextReviewAt = now.addingTimeInterval(-1)
            }
            try payload.validate()
            let url = root.appending(path: "performance-\(size).sqlite")
            try autoreleasepool {
                let seed = try V3TestSupport.container(url: url)
                try payload.populateEmptyStore(seed.mainContext)
            }
            let container = try V3TestSupport.container(url: url)
            let content = try WordNoteV3ContentService(container: container)
            let review = try WordNoteV3ReviewService(container: container)
            var metrics: [String: [Double]] = [:]

            // The first full cycle warms the reopened disk store and is excluded from the report.
            for iteration in 0...iterations {
                func measure<T>(_ name: String, _ operation: () throws -> T) rethrows -> T {
                    let start = ContinuousClock.now
                    let result = try operation()
                    if iteration > 0 { metrics[name, default: []].append(milliseconds(since: start)) }
                    return result
                }
                let queued = try measure("capture_queued_ms") {
                    try content.capture(.init(rawText: "unseen benchmark input \(iteration)"), at: now)
                }
                guard case .inputRecord(_, .queued) = queued.destination else {
                    return XCTFail("A new capture must be durably queued without a provider call.")
                }
                let local = try measure("capture_local_hit_ms") {
                    try content.capture(.init(rawText: "synthetic vocabulary term \(iteration)"), at: now)
                }
                guard case .vocabulary = local.destination else {
                    return XCTFail("Exact capture must use the local vocabulary.")
                }
                let session = try measure("review_start_ms") {
                    try review.startSession(scope: .init(studyTimeZoneID: "Asia/Hong_Kong"), targetCardCount: 5, at: now)
                }
                let lease = try review.acquireLease(sessionID: session.session.id, ownerID: UUID())
                let shown = try measure("review_present_ms") {
                    let source = try XCTUnwrap(review.presentNextCard(lease: lease,
                        expectedRevision: session.session.revision, at: now))
                    _ = try review.questionFront(sessionID: lease.sessionID)
                    _ = try review.reviewSession(lease.sessionID)
                    _ = try review.sessionStatistics(lease.sessionID, at: now)
                    return source
                }
                let preview = try measure("review_reveal_and_previews_ms") {
                    _ = try review.revealAnswer(shown, lease: lease, at: now)
                    _ = try review.revealedQuestion(lease: lease)
                    let previews = try ReviewFeedback.allCases.map { try review.previewFeedback($0, lease: lease, at: now) }
                    _ = try review.reviewSession(lease.sessionID)
                    _ = try review.sessionStatistics(lease.sessionID, at: now)
                    return try XCTUnwrap(previews.first { $0.plan.feedback == .good })
                }
                let actionID = UUID()
                let answer = try measure("review_answer_and_advance_ms") {
                    let receipt = try review.recordFeedback(preview, actionID: actionID, lease: lease, at: now)
                    let current = try review.reviewSession(lease.sessionID)
                    _ = try review.presentNextCard(lease: lease, expectedRevision: current.session.revision, at: now)
                    _ = try review.questionFront(sessionID: lease.sessionID)
                    _ = try review.reviewSession(lease.sessionID)
                    _ = try review.sessionStatistics(lease.sessionID, at: now)
                    return receipt
                }
                XCTAssertFalse(answer.isReplay)
                XCTAssertEqual(try review.feedbackReceipt(actionID: actionID)?.eventID, answer.eventID)
                let current = try review.reviewSession(lease.sessionID)
                _ = try review.endSession(lease: lease, expectedRevision: current.session.revision, at: now)
                if iteration > 0, iteration % 5 == 0 || iteration == iterations {
                    print("V3 benchmark progress: terms=\(size), iteration=\(iteration)/\(iterations)")
                }
            }
            let final = try WordNoteSnapshotV3Payload.capture(from: container.mainContext)
            XCTAssertEqual(final.content.content.terms.count, size)
            XCTAssertEqual(final.content.lookupEvents.count, iterations + 1)
            XCTAssertEqual(final.eventStates.filter { $0.feedbackSemanticsVersion == 2 }.count, iterations + 1)
            let report = Report(termCount: size, initialEntities: payload.counts.total, iterations: iterations,
                scope: "release; reopened V3 SQLite; synchronous MainActor services; excludes SwiftUI rendering, input and network",
                metrics: metrics.mapValues(Distribution.init))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print("V3_SERVICE_PERFORMANCE \(String(decoding: try encoder.encode(report), as: UTF8.self))")
            withExtendedLifetime(container) {}
        }
        #endif
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = (ContinuousClock.now - start).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1_000_000_000_000_000
    }

    private struct Distribution: Encodable {
        let p50: Double
        let p95: Double
        let max: Double
        init(_ values: [Double]) {
            let sorted = values.sorted()
            p50 = sorted[Int(ceil(Double(sorted.count) * 0.50)) - 1]
            p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
            max = sorted.last!
        }
    }

    private struct Report: Encodable {
        let termCount: Int
        let initialEntities: Int
        let iterations: Int
        let scope: String
        let metrics: [String: Distribution]
    }
}
