import XCTest
@testable import WordNoteCore

@MainActor
final class InboxBrowseIndexTests: XCTestCase {
    private typealias Values = InboxTestValues

    func testPreviewSeparatesUserContentFromStatusFallback() {
        let record = Values.record()
        let empty = InboxBrowseItem(record: record, candidates: [])
        XCTAssertNil(empty.previewText)
        XCTAssertEqual(empty.preview, empty.statusTitle)

        record.sentenceMeaning = "Draft"
        let content = InboxBrowseItem(record: record, candidates: [])
        XCTAssertEqual(content.previewText, "Draft")
        XCTAssertEqual(content.preview, "Draft")
    }

    func testSearchMatchesSourceNoteSentenceAndCandidateFieldsWithChineseVariants() {
        let record = Values.record("A source sentence")
        record.note = "課堂筆記"
        record.sentenceMeaning = "資料結構"
        let candidate = Values.candidate("throughput", record: record)
        candidate.chineseMeaning = "吞吐量；處理速度"
        candidate.englishDefinition = "The processing capacity"
        let index = InboxBrowseIndex(items: [.init(record: record, candidates: [candidate])])
        for text in ["source", "课堂", "資料", "资料", "THROUGHPUT", "处理", "capacity", " \n "] {
            var query = InboxBrowseQuery()
            query.text = text
            XCTAssertEqual(index.matching(query).active.map(\.id), [record.id], text)
        }
        var query = InboxBrowseQuery()
        query.text = "unrelated"
        XCTAssertTrue(index.matching(query).active.isEmpty)
    }

    func testCourseSourceStatusAndSearchAreConjunctiveCaptureFilters() {
        let record = Values.record(), courseID = UUID()
        record.courseID = courseID
        record.sourceType = .paper
        let index = InboxBrowseIndex(items: [.init(record: record, candidates: [Values.candidate(record: record)])])
        var query = InboxBrowseQuery()
        query.text = "quick"
        query.courseID = courseID
        query.source = .paper
        query.status = .pending
        XCTAssertEqual(index.matching(query).active.map(\.id), [record.id])
        query.courseID = UUID()
        XCTAssertTrue(index.matching(query).active.isEmpty)
        query.courseID = courseID
        query.source = .other
        XCTAssertTrue(index.matching(query).active.isEmpty)
        query.source = .paper
        query.status = .drafts
        XCTAssertTrue(index.matching(query).active.isEmpty)
    }

    func testPendingAndFailedOverlapWithoutLosingOldCandidates() {
        let record = Values.record()
        record.queueStateRaw = "failed"
        let item = InboxBrowseItem(record: record, candidates: [Values.candidate(record: record)])
        for status in [InboxStatusFilter.all, .pending, .failed] {
            var query = InboxBrowseQuery()
            query.status = status
            let result = InboxBrowseIndex(items: [item]).matching(query)
            XCTAssertEqual(result.active.map(\.id), [record.id])
            XCTAssertEqual(result.confirmableIDs, [record.id])
        }
    }

    func testDraftFilterIncludesCancelledEmptyDraftButNotFailuresOrCandidates() {
        let draft = Values.record(), cancelled = Values.record(), failed = Values.record(), analyzed = Values.record()
        cancelled.queueStateRaw = "cancelled"
        failed.queueStateRaw = "failed"
        let items = [draft, cancelled, failed].map { InboxBrowseItem(record: $0, candidates: []) }
            + [InboxBrowseItem(record: analyzed, candidates: [Values.candidate(record: analyzed)])]
        var query = InboxBrowseQuery()
        query.status = .drafts
        XCTAssertEqual(Set(InboxBrowseIndex(items: items).matching(query).active.map(\.id)), [draft.id, cancelled.id])
    }

    func testQueuedRunningAndIgnoredNeverEnterPrimaryListOrBatch() {
        let items = ["queued", "running", "none"].map { state in
            let record = Values.record()
            record.queueStateRaw = state
            if state == "none" { record.status = .ignored }
            return InboxBrowseItem(record: record, candidates: [Values.candidate(record: record)])
        }
        for status in InboxStatusFilter.allCases {
            var query = InboxBrowseQuery()
            query.status = status
            let result = InboxBrowseIndex(items: items).matching(query)
            XCTAssertTrue(result.active.isEmpty)
            XCTAssertTrue(result.handled.isEmpty)
            XCTAssertTrue(result.confirmableIDs.isEmpty)
        }
    }

    func testHandledIncludesAllIgnoredButOnlyUnderAllAndMatchingScope() {
        let record = Values.record()
        record.status = .completed
        record.sourceType = .paper
        let candidate = Values.candidate(record: record)
        candidate.status = .ignored
        let index = InboxBrowseIndex(items: [.init(record: record, candidates: [candidate])])
        var query = InboxBrowseQuery()
        query.text = "quick"
        query.source = .paper
        XCTAssertEqual(index.matching(query).handled.map(\.id), [record.id])
        XCTAssertTrue(index.matching(query).active.isEmpty)
        XCTAssertTrue(index.matching(query).confirmableIDs.isEmpty)
        query.status = .pending
        XCTAssertTrue(index.matching(query).handled.isEmpty)
        query.status = .all
        query.source = .other
        XCTAssertTrue(index.matching(query).handled.isEmpty)
        record.queueStateRaw = "running"
        XCTAssertTrue(InboxBrowseIndex(items: [.init(record: record, candidates: [candidate])]).matching(.init()).handled.isEmpty)
    }

    func testPreviewPrefersPendingAndUsesEighteenCharactersWithoutMutatingDefinition() {
        let record = Values.record()
        let old = Values.candidate("old", record: record), pending = Values.candidate(record: record)
        old.status = .saved
        old.chineseMeaning = "已保存的釋義"
        pending.chineseMeaning = "  第一義\n第二義\t第三義第四義第五義第六義第七義  "
        let item = InboxBrowseItem(record: record, candidates: [old, pending])
        XCTAssertEqual(item.preview, String("第一義 第二義 第三義第四義第五義第六義第七義".prefix(18)))
        XCTAssertEqual(item.preview.count, 18)
        XCTAssertEqual(item.pendingCandidates.first?.chineseMeaning, pending.chineseMeaning)
    }

    func testPreviewUsesFrozenDirectionNotRawInputDetection() {
        let record = Values.record("English raw input with manual direction")
        record.resolvedLookupDirectionRaw = "chineseToEnglish"
        let candidate = Values.candidate("a long English candidate", record: record)
        candidate.chineseMeaning = "中文釋義"
        XCTAssertEqual(InboxBrowseItem(record: record, candidates: [candidate]).preview, "a long English can")
        record.resolvedLookupDirectionRaw = "englishToChinese"
        XCTAssertEqual(InboxBrowseItem(record: record, candidates: [candidate]).preview, "中文釋義")
    }

    func testPreviewPreservesGraphemeClustersAndFallsBackToSentenceOrStatus() {
        let record = Values.record()
        record.sentenceMeaning = String(repeating: "e\u{301}", count: 20)
        let preview = InboxBrowseItem(record: record, candidates: []).preview
        XCTAssertEqual(preview, String(repeating: "e\u{301}", count: 18))
        XCTAssertEqual(preview.count, 18)
        record.sentenceMeaning = " \n "
        record.queueStateRaw = "cancelled"
        XCTAssertEqual(InboxBrowseItem(record: record, candidates: []).preview, "Analysis cancelled")
    }

    func testStaleGenerationAndUnknownQueueCannotBeBatchConfirmed() {
        let record = Values.record()
        let candidate = Values.candidate(record: record)
        record.analysisGeneration = 2
        XCTAssertFalse(InboxBrowseItem(record: record, candidates: [candidate]).canConfirm)
        candidate.analysisGeneration = 2
        XCTAssertTrue(InboxBrowseItem(record: record, candidates: [candidate]).canConfirm)
        record.queueStateRaw = "future-state"
        XCTAssertFalse(InboxBrowseItem(record: record, candidates: [candidate]).canConfirm)
    }

    func testIndexFreezesValuesAndExcludesCandidatesFromOtherRecords() {
        let record = Values.record(), other = Values.record()
        let candidate = Values.candidate(record: record)
        let item = InboxBrowseItem(record: record, candidates: [candidate, Values.candidate(record: other)])
        record.revision += 1
        candidate.chineseMeaning = "Changed later"
        candidate.revision += 1
        XCTAssertEqual(item.candidates.count, 1)
        XCTAssertEqual(item.state.revision, 0)
        XCTAssertEqual(item.selections.first?.revision, 0)
        XCTAssertEqual(item.selections.first?.recordRevision, 0)
        XCTAssertEqual(item.preview, "快速的")
    }

    func testSelectedCountsIgnoreHiddenUnknownHandledAndStaleIDs() {
        let record = Values.record(), draft = Values.record(), stale = Values.record()
        let candidates = [Values.candidate("quick", record: record), Values.candidate("throughput", record: record)]
        stale.analysisGeneration = 1
        let result = InboxBrowseIndex(items: [.init(record: record, candidates: candidates), .init(record: draft, candidates: []),
            .init(record: stale, candidates: [Values.candidate(record: stale)])]).matching(.init())
        let counts = result.selectedCounts([record.id, draft.id, stale.id, UUID()])
        XCTAssertEqual(counts.records, 1)
        XCTAssertEqual(counts.candidates, 2)
    }

    func testOrderingIsNewestFirstWithStableIDTiesRegardlessOfFetchOrder() {
        let first = Values.record(), second = Values.record(), newest = Values.record()
        first.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        second.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        newest.createdAt = first.createdAt.addingTimeInterval(1)
        for records in [[second, newest, first], [first, second, newest]] {
            let result = InboxBrowseIndex(items: records.map { .init(record: $0, candidates: []) }).matching(.init())
            XCTAssertEqual(result.active.map(\.id), [newest.id, first.id, second.id])
        }
    }
}

@MainActor
enum InboxTestValues {
    static func record(_ text: String = "Synthetic source") -> WordNoteSchemaV2.InputRecordModel {
        .init(rawText: text, createdAt: WordNoteV2ServiceTestSupport.now, updatedAt: WordNoteV2ServiceTestSupport.now)
    }

    static func candidate(_ text: String = "quick", record: WordNoteSchemaV2.InputRecordModel) -> WordNoteSchemaV2.CandidateTermModel {
        .init(inputRecordID: record.id, term: text, termType: .word, needToLearn: true, importance: .medium,
              category: .general, chineseMeaning: "快速的", createdAt: WordNoteV2ServiceTestSupport.now,
              updatedAt: WordNoteV2ServiceTestSupport.now)
    }
}
