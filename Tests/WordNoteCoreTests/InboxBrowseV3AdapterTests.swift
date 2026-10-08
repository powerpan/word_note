import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class InboxBrowseV3AdapterTests: XCTestCase {
    func testMigratedRecordsKeepTheSameBrowseAndConfirmationValues() throws {
        let old = try WordNoteV2ServiceTestSupport.container()
        let migrated = try WordNoteV2ToV3Migration.convert(WordNoteV2ServiceTestSupport.snapshot(old), at: WordNoteV3ServiceTestSupport.now)
        let new = try WordNoteV3ServiceTestSupport.container(populated: false)
        try migrated.populateEmptyStore(new.mainContext)
        let oldCandidates = try old.mainContext.fetch(FetchDescriptor<WordNoteSchemaV2.CandidateTermModel>())
        let newCandidates = try new.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.CandidateTermModel>())
        let oldRecords = try old.mainContext.fetch(FetchDescriptor<WordNoteSchemaV2.InputRecordModel>())
        for record in try new.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.InputRecordModel>()) {
            let original = try XCTUnwrap(oldRecords.first { $0.id == record.id })
            let left = InboxBrowseItem(record: original, candidates: oldCandidates)
            let right = InboxBrowseItem(record: record, candidates: newCandidates)
            XCTAssertEqual(left.record, right.record)
            XCTAssertEqual(left.state, right.state)
            XCTAssertEqual(left.candidates, right.candidates)
            XCTAssertEqual(left.selections.map(\.id), right.selections.map(\.id))
            XCTAssertEqual(left.selections.map(\.revision), right.selections.map(\.revision))
            XCTAssertEqual(left.selections.map(\.recordID), right.selections.map(\.recordID))
            XCTAssertEqual(left.selections.map(\.recordRevision), right.selections.map(\.recordRevision))
            XCTAssertEqual(left.preview, right.preview)
            XCTAssertEqual(left.canConfirm, right.canConfirm)
        }
    }

    func testV3FrozenDirectionPreviewAndStaleCandidateGeneration() {
        let record = WordNoteSchemaV3.InputRecordModel(rawText: "throughput")
        record.resolvedLookupDirectionRaw = "chineseToEnglish"
        record.analysisGeneration = 2
        let candidate = WordNoteSchemaV3.CandidateTermModel(inputRecordID: record.id, term: "throughput",
            termType: .word, needToLearn: true, importance: .medium, category: .general, chineseMeaning: "吞吐量")
        let stale = InboxBrowseItem(record: record, candidates: [candidate])
        XCTAssertFalse(stale.canConfirm)
        XCTAssertEqual(stale.preview, "throughput")
        candidate.analysisGeneration = 2
        let item = InboxBrowseItem(record: record, candidates: [candidate])
        XCTAssertTrue(item.canConfirm)
        var query = InboxBrowseQuery()
        query.text = "吞吐"
        XCTAssertEqual(InboxBrowseIndex(items: [item]).matching(query).confirmableIDs, [record.id])
        record.queueStateRaw = "running"
        XCTAssertFalse(InboxBrowseItem(record: record, candidates: [candidate]).isActive)
    }
}
