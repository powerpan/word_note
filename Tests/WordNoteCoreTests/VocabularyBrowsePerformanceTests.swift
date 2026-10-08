import XCTest
@testable import WordNoteCore

@MainActor
final class VocabularyBrowsePerformanceTests: XCTestCase {
    func testPreparedBrowseIndexPerformance() throws {
        guard ProcessInfo.processInfo.environment["RUN_VOCABULARY_PERFORMANCE_TESTS"] == "1" else {
            throw XCTSkip("Opt in with RUN_VOCABULARY_PERFORMANCE_TESTS=1 and swift test -c release.")
        }
        #if DEBUG
        throw XCTSkip("Vocabulary performance evidence requires a Release build.")
        #else
        let seed = VocabularyTestValues.term("synthetic", chinese: "計算機；資料結構；用於描述資料組織及處理方式的合成測試釋義。", english: "A synthetic vocabulary fixture.")
        let now = VocabularyTestValues.now
        for size in [1_000, 10_000] {
            let terms = (0..<size).map { number in
                let position = (number * 7_919) % size
                var value = seed
                value.id = UUID()
                value.term = "synthetic term \(position)"
                value.normalizedTerm = value.term
                value.tags = [position.isMultiple(of: 2) ? "Even" : "Odd"]
                return value
            }
            var metrics: [String: [Double]] = [:]
            for iteration in 0...30 {
                autoreleasepool {
                    func record<T>(_ name: String, _ action: () -> T) -> T {
                        let start = ContinuousClock.now
                        let result = action()
                        let duration = (ContinuousClock.now - start).components
                        if iteration > 0 {
                            metrics[name, default: []].append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
                        }
                        return result
                    }
                    let index = record("index_build_ms") { VocabularyBrowseIndex(terms: terms) }
                    var query = VocabularyBrowseQuery()
                    query.text = "synthetic"
                    let english = record("english_query_ms") { index.matching(query, at: now) }
                    XCTAssertEqual(english.count, size)
                    query.text = "计算机"
                    let chinese = record("chinese_query_ms") { index.matching(query, at: now) }
                    XCTAssertEqual(chinese.count, size)
                    query.tag = "even"
                    query.sort = .alphabetical
                    let filtered = record("filter_sort_ms") { index.matching(query, at: now) }
                    XCTAssertEqual(filtered.count, size / 2)
                }
            }
            let report = Report(terms: size, iterations: 30, metrics: metrics.mapValues(Distribution.init))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print("VOCABULARY_PERFORMANCE \(String(decoding: try encoder.encode(report), as: UTF8.self))")
        }
        #endif
    }

    private struct Report: Encodable {
        let terms: Int
        let iterations: Int
        let configuration = "release"
        let inputOrder = "deterministically permuted; not presorted"
        let scope = "value-index-only; excludes SwiftData fetch, SwiftUI rendering and input latency"
        let metrics: [String: Distribution]
    }

    private struct Distribution: Encodable {
        let p50: Double
        let p95: Double
        let max: Double
        init(_ values: [Double]) {
            let sorted = values.sorted()
            p50 = sorted[Int(ceil(Double(sorted.count) * 0.5)) - 1]
            p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
            max = sorted.last ?? 0
        }
    }
}
