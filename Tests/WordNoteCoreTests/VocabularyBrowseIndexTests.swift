import XCTest
@testable import WordNoteCore

@MainActor
final class VocabularyBrowseIndexTests: XCTestCase {
    private typealias Values = VocabularyTestValues
    private let now = Values.now

    func testPreparedSearchRetainsEnglishDefinitionAndChineseVariants() {
        let term = Values.term("C++", chinese: "計算機；資料結構", english: "A programming language")
        let index = VocabularyBrowseIndex(terms: [term])
        for text in ["C++", "c++", "programming", "计算机", "資料結構", "资料结构", " \n "] {
            var query = VocabularyBrowseQuery()
            query.text = text
            XCTAssertEqual(index.matching(query, at: now).map(\.id), [term.id], text)
        }
        for text in ["不存在", "!?", "unrelated"] {
            var query = VocabularyBrowseQuery()
            query.text = text
            XCTAssertTrue(index.matching(query, at: now).isEmpty, text)
        }
    }

    func testFiltersAreConjunctiveAndUseMembershipsNotLegacyOrigin() {
        let course = UUID(), legacy = UUID()
        var first = Values.term("quick", chinese: "快速的")
        first.tags = [" Core   Words "]
        first.courseID = legacy
        first.masteryLevelRaw = MasteryLevel.familiar.rawValue
        let second = Values.term("quickly", chinese: "快速地")
        let index = VocabularyBrowseIndex(terms: [first, second], courseLinks: [Values.link(first.id, course)])
        var query = VocabularyBrowseQuery()
        query.text = "快速"
        query.courseID = course
        query.mastery = .familiar
        query.tag = "core words"
        XCTAssertEqual(index.matching(query, at: now).map(\.id), [first.id])
        query.courseID = legacy
        XCTAssertTrue(index.matching(query, at: now).isEmpty)
        query.courseID = course
        query.mastery = .new
        XCTAssertTrue(index.matching(query, at: now).isEmpty)
        query.mastery = .familiar
        query.tag = "missing"
        XCTAssertTrue(index.matching(query, at: now).isEmpty)
    }

    func testRecentRequeryUsesInclusiveSevenDaysAndExcludesFuture() {
        let boundary = Values.term("boundary"), old = Values.term("old"), future = Values.term("future")
        let start = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let index = VocabularyBrowseIndex(terms: [boundary, old, future], lookupEvents: [
            Values.event(boundary.id, at: start), Values.event(old.id, at: start.addingTimeInterval(-1)),
            Values.event(future.id, at: now.addingTimeInterval(1))
        ])
        var query = VocabularyBrowseQuery()
        query.activity = .recentRequery
        XCTAssertEqual(index.matching(query, at: now).map(\.id), [boundary.id])
        XCTAssertEqual(index.matching(query, at: now.addingTimeInterval(1)).map(\.id), [future.id])
    }

    func testRepeatFilterCountsDistinctCapturesNotLegacyCounters() {
        var legacy = Values.term("legacy")
        legacy.wrongCount = 99
        legacy.duplicateHitCount = 99
        legacy.lastDuplicateHitAt = now
        let once = Values.term("once"), twice = Values.term("twice"), capture = UUID()
        let index = VocabularyBrowseIndex(terms: [legacy, once, twice], lookupEvents: [
            Values.event(once.id, capture: capture, at: now), Values.event(once.id, capture: capture, at: now),
            Values.event(twice.id, at: now.addingTimeInterval(-10)), Values.event(twice.id, at: now),
            Values.event(once.id, at: now.addingTimeInterval(1))
        ])
        var query = VocabularyBrowseQuery()
        query.activity = .repeatedRequery
        XCTAssertEqual(index.matching(query, at: now).map(\.id), [twice.id])
        XCTAssertEqual(index.items.first { $0.id == once.id }?.requeryCount(at: now), 1)
        XCTAssertEqual(Set(index.matching(query, at: now.addingTimeInterval(1)).map(\.id)), [once.id, twice.id])
    }

    func testUnknownAndNonfiniteEventsAreNotPresentedAsLookupHistory() {
        let term = Values.term("quick")
        var unknown = Values.event(term.id, at: now)
        unknown.kindRaw = "future-kind"
        var invalid = Values.event(term.id, at: now)
        invalid.occurredAt = Date(timeIntervalSince1970: .infinity)
        let index = VocabularyBrowseIndex(terms: [term], lookupEvents: [unknown, invalid, Values.event(UUID(), at: now)])
        XCTAssertEqual(index.items[0].requeryCount(at: now), 0)
        XCTAssertNil(index.items[0].lastRequery(at: now))
    }

    func testRepeatedCaptureHasDeterministicEarliestTimestamp() {
        let term = Values.term("quick"), capture = UUID()
        let events = [Values.event(term.id, capture: capture, at: now),
                      Values.event(term.id, capture: capture, at: now.addingTimeInterval(-10))]
        for input in [events, events.reversed()] {
            let item = VocabularyBrowseIndex(terms: [term], lookupEvents: input).items[0]
            XCTAssertEqual(item.requeryCount(at: now), 1)
            XCTAssertEqual(item.lastRequery(at: now), now.addingTimeInterval(-10))
        }
    }

    func testDateSortsAndRequerySortsUseExpectedOrderWithNilLast() {
        var a = Values.term("alpha"), b = Values.term("beta"), c = Values.term("gamma")
        a.createdAt = now; b.createdAt = now.addingTimeInterval(-1); c.createdAt = now.addingTimeInterval(-2)
        a.updatedAt = now.addingTimeInterval(-2); b.updatedAt = now; c.updatedAt = now.addingTimeInterval(-1)
        let index = VocabularyBrowseIndex(terms: [a, b, c], lookupEvents: [
            Values.event(c.id, at: now.addingTimeInterval(-2)), Values.event(c.id, at: now.addingTimeInterval(-1)),
            Values.event(b.id, at: now), Values.event(a.id, at: now.addingTimeInterval(20))
        ])
        let orders: [(VocabularySort, [UUID])] = [(.updated, [b.id, c.id, a.id]), (.added, [a.id, b.id, c.id]),
            (.alphabetical, [a.id, b.id, c.id]), (.lastRequery, [b.id, c.id, a.id]), (.mostRequeried, [c.id, b.id, a.id])]
        for (sort, expected) in orders {
            var query = VocabularyBrowseQuery()
            query.sort = sort
            XCTAssertEqual(index.matching(query, at: now).map(\.id), expected, sort.rawValue)
        }
    }

    func testSortTiesAreStableAcrossFetchOrderAndUseNumericEnglishOrdering() throws {
        var first = Values.term("Term 2"), second = Values.term("term 2"), last = Values.term("term 10")
        first.id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        second.id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        last.id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        for sort in VocabularySort.allCases {
            var query = VocabularyBrowseQuery()
            query.sort = sort
            for values in [[last, second, first], [second, first, last]] {
                XCTAssertEqual(VocabularyBrowseIndex(terms: values).matching(query, at: now).map(\.id), [first.id, second.id, last.id])
            }
        }
    }

    func testSummaryAndTagOptionsDoNotMutateFullReadingValues() {
        var term = Values.term("quick", chinese: "第一義\n  第二義\t第三義")
        term.tags = [" Core  Words ", "core words", "", "  ", "Other"]
        let index = VocabularyBrowseIndex(terms: [term])
        XCTAssertEqual(index.items[0].chineseSummary, "第一義 第二義 第三義")
        XCTAssertEqual(index.items[0].term, term)
        XCTAssertEqual(index.tags.map(\.id), ["core words", "other"])
        XCTAssertEqual(index.tags.first?.label, "Core  Words")
    }

    func testOnlySortChangesPreserveScope() {
        let original = VocabularyBrowseQuery()
        var changed = original
        changed.sort = .alphabetical
        XCTAssertTrue(original.hasSameScope(as: changed))
        changed.text = "quick"
        XCTAssertFalse(original.hasSameScope(as: changed))
        changed = original; changed.courseID = UUID()
        XCTAssertFalse(original.hasSameScope(as: changed))
        changed = original; changed.mastery = .mastered
        XCTAssertFalse(original.hasSameScope(as: changed))
        changed = original; changed.tag = "core"
        XCTAssertFalse(original.hasSameScope(as: changed))
        changed = original; changed.activity = .recentRequery
        XCTAssertFalse(original.hasSameScope(as: changed))
    }
}

@MainActor
enum VocabularyTestValues {
    static let now = WordNoteV2ServiceTestSupport.now

    static func term(_ text: String, chinese: String? = nil, english: String? = nil) -> WordNoteSnapshotPayload.Term {
        .init(WordNoteSchemaV2.TermModel(term: text, termType: .word, chineseMeaning: chinese, englishDefinition: english,
                                       nextReviewAt: nil, createdAt: now, updatedAt: now))
    }

    static func event(_ termID: UUID, capture: UUID = UUID(), at date: Date) -> WordNoteSnapshotV2Payload.LookupEvent {
        .init(WordNoteSchemaV2.LookupEventModel(termID: termID, captureID: capture, occurredAt: date, createdAt: date))
    }

    static func link(_ termID: UUID, _ courseID: UUID) -> WordNoteSnapshotV2Payload.CourseLink {
        .init(WordNoteSchemaV2.TermCourseLinkModel(termID: termID, courseID: courseID, createdAt: now))
    }

    static func occurrence(_ termID: UUID, sourceID: UUID? = nil, text: String, note: String? = nil, at date: Date = now)
        -> WordNoteSnapshotV2Payload.Occurrence {
        .init(WordNoteSchemaV2.TermOccurrenceModel(termID: termID, captureID: UUID(), sourceRecordID: sourceID,
            rawTextSnapshot: text, note: note, occurredAt: date, capturedVia: .mainQuickAdd, createdAt: date))
    }
}
