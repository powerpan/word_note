import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteBackupPerformanceTests: XCTestCase {
    func testScaledBackupAndRestorePerformance() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_BACKUP_PERFORMANCE_TESTS"] == "1" else {
            throw XCTSkip("Opt in with RUN_BACKUP_PERFORMANCE_TESTS=1 and swift test -c release.")
        }
        #if DEBUG
        throw XCTSkip("Backup performance evidence requires a Release build.")
        #else
        let iterations = Int(environment["BACKUP_PERFORMANCE_ITERATIONS"] ?? "30") ?? 30
        let sizes = environment["BACKUP_PERFORMANCE_SIZE"].flatMap(Int.init).map { [$0] } ?? [1_000, 10_000]
        XCTAssertTrue((1...100).contains(iterations))
        XCTAssertTrue(sizes.allSatisfy { [1_000, 10_000].contains($0) })
        guard (1...100).contains(iterations), sizes.allSatisfy({ [1_000, 10_000].contains($0) }) else { return }
        let root = FileManager.default.temporaryDirectory.appending(path: "backup-performance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        for size in sizes {
            let payload = try scaledPayload(termCount: size)
            let source = WordNoteRestoreStore(directoryURL: root.appending(path: "source-\(size)"))
            let session = try source.open()
            defer { withExtendedLifetime(session.container) {} }
            try payload.populateEmptyStore(session.container.mainContext)
            let data = try WordNoteSnapshotCodec.encode(payload, kind: .manual)
            let decoded = try WordNoteSnapshotCodec.decode(data)
            var metrics: [String: [Double]] = [:]

            // The first complete pass warms schema, codec and filesystem paths but is not reported.
            for iteration in 0...iterations {
                func record<T>(_ name: String, _ operation: () throws -> T) rethrows -> T {
                    let start = ContinuousClock.now
                    let result = try operation()
                    if iteration > 0 { metrics[name, default: []].append(milliseconds(since: start)) }
                    return result
                }

                let captured = try record("capture_main_ms") {
                    try WordNoteSnapshotPayload.capture(from: session.container.mainContext)
                }
                XCTAssertEqual(captured, payload)
                let capture = try await responsiveOperation {
                    try await WordNoteSnapshotCapture(container: session.container).capture()
                }
                if iteration > 0 {
                    metrics["capture_background_ms", default: []].append(capture.elapsed)
                    metrics["capture_main_actor_max_gap_ms", default: []].append(capture.mainActorGap)
                }
                XCTAssertEqual(capture.value, payload)
                let encoded = try record("encode_ms") {
                    try WordNoteSnapshotCodec.encode(captured, kind: .manual)
                }
                let roundTrip = try record("decode_ms") { try WordNoteSnapshotCodec.decode(encoded) }
                XCTAssertEqual(roundTrip.payload, payload)

                let destination = root.appending(path: "restore-\(size)-\(iteration)")
                let store = WordNoteRestoreStore(directoryURL: destination)
                let empty = try store.open()
                let vault = WordNoteBackupVault(directoryURL: destination.appending(path: "Backups"))
                let protection = try await vault.create(
                    WordNoteSnapshotPayload.capture(from: empty.container.mainContext), kind: .beforeRestore
                )
                let prepare = try await responsiveOperation {
                    try await store.prepareRestore(decoded, replacing: empty.generation, protectedBy: protection.snapshot)
                }
                if iteration > 0 {
                    metrics["prepare_background_ms", default: []].append(prepare.elapsed)
                    metrics["prepare_main_actor_max_gap_ms", default: []].append(prepare.mainActorGap)
                }
                try autoreleasepool {
                    let restored = try record("activate_main_ms") { try store.open() }
                    XCTAssertEqual(restored.generation, prepare.value)
                    XCTAssertEqual(restored.restoreOutcome, .restored)
                    XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: restored.container.mainContext), payload)
                    withExtendedLifetime(restored.container) {}
                }
                let backupStart = ContinuousClock.now
                _ = try await vault.create(captured, kind: .manual)
                if iteration > 0 { metrics["vault_create_ms", default: []].append(milliseconds(since: backupStart)) }
                withExtendedLifetime(empty.container) {}
                try FileManager.default.removeItem(at: destination)
                if iteration > 0, iteration % 5 == 0 || iteration == iterations {
                    print("Backup benchmark progress: terms=\(size), iteration=\(iteration)/\(iterations)")
                }
            }
            let report = BenchmarkReport(
                termCount: size, totalEntities: payload.counts.total, snapshotBytes: data.count,
                iterations: iterations, configuration: "release",
                metrics: metrics.mapValues(Distribution.init)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print("BACKUP_PERFORMANCE \(String(decoding: try encoder.encode(report), as: UTF8.self))")
        }
        #endif
    }

    private func scaledPayload(termCount: Int) throws -> WordNoteSnapshotPayload {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        defer { withExtendedLifetime(container) {} }
        try WordNoteTestFixture.populated.populate(container.mainContext)
        let seed = try WordNoteSnapshotPayload.capture(from: container.mainContext)
        var result = WordNoteSnapshotPayload(courses: seed.courses, inputRecords: [], candidates: [], terms: [], reviewEvents: [], preferences: .init())
        for index in 0..<termCount {
            let termID = id(index, family: 1)
            let recordID = id(index, family: 2)
            let courseID = seed.courses[index % seed.courses.count].id
            let termText = "synthetic vocabulary term \(index)"
            var record = seed.inputRecords[index % seed.inputRecords.count]
            record.id = recordID
            record.rawText = "An example sentence containing \(termText) for a local performance fixture."
            record.normalizedText = TextNormalizer.normalized(record.rawText)
            record.statusRaw = InputRecordStatus.completed.rawValue
            record.courseID = courseID
            var candidate = seed.candidates[index % seed.candidates.count]
            candidate.id = id(index, family: 3)
            candidate.inputRecordID = recordID
            candidate.term = termText
            candidate.normalizedTerm = TextNormalizer.normalized(termText)
            candidate.statusRaw = CandidateStatus.saved.rawValue
            var term = seed.terms[index % seed.terms.count]
            term.id = termID
            term.term = termText
            term.normalizedTerm = candidate.normalizedTerm
            term.sourceRecordID = recordID
            term.courseID = courseID
            var event = seed.reviewEvents[0]
            event.id = id(index, family: 4)
            event.termID = termID
            result.inputRecords.append(record)
            result.candidates.append(candidate)
            result.terms.append(term)
            result.reviewEvents.append(event)
        }
        try result.validate()
        return result.canonicalized
    }

    private func id(_ index: Int, family: Int) -> UUID {
        UUID(uuidString: String(format: "%08x-0000-0000-0000-%012x", family, index))!
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = (ContinuousClock.now - start).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1_000_000_000_000_000
    }

    private func responsiveOperation<T>(
        _ operation: () async throws -> T
    ) async rethrows -> (value: T, elapsed: Double, mainActorGap: Double) {
        let pulse = MainActorPulse()
        pulse.start()
        await Task.yield()
        let start = ContinuousClock.now
        do {
            let value = try await operation()
            let elapsed = milliseconds(since: start)
            return (value, elapsed, await pulse.stop())
        } catch {
            _ = await pulse.stop()
            throw error
        }
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

    private struct BenchmarkReport: Encodable {
        let termCount: Int
        let totalEntities: Int
        let snapshotBytes: Int
        let iterations: Int
        let configuration: String
        let metrics: [String: Distribution]
    }
}

@MainActor
private final class MainActorPulse {
    private var task: Task<Void, Never>?
    private var maximumGap = 0.0

    func start() {
        let startedAt = ContinuousClock.now
        task = Task { @MainActor [weak self] in
            var previous = startedAt
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000) }
                catch { return }
                let now = ContinuousClock.now
                let gap = (now - previous).components
                let milliseconds = Double(gap.seconds) * 1_000 + Double(gap.attoseconds) / 1_000_000_000_000_000
                self?.maximumGap = max(self?.maximumGap ?? 0, milliseconds)
                previous = now
            }
        }
    }

    func stop() async -> Double {
        try? await Task.sleep(nanoseconds: 12_000_000)
        task?.cancel()
        await task?.value
        task = nil
        return maximumGap
    }
}
