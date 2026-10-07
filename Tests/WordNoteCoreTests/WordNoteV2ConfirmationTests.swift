import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2ConfirmationTests: XCTestCase {
    private typealias Support = WordNoteV2ServiceTestSupport

    func testNewCandidateConfirmationAtomicallySavesTermSourceCourseAndRevisions() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let candidate = try Support.candidate("throughput", in: container)
        let record = try Support.record(candidate.inputRecordID, in: container)
        let operation = UUID()
        let result = try service.confirmCandidate(candidate.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: operation, target: .createNew, at: Support.now)
        let term = try Support.term("throughput", in: container)
        let snapshot = try Support.snapshot(container)
        XCTAssertEqual(result.id, term.id)
        XCTAssertEqual(result.revision, 0)
        XCTAssertEqual(candidate.statusRaw, "saved")
        XCTAssertEqual(candidate.savedTermID, term.id)
        XCTAssertEqual(candidate.savedLinkStateRaw, "resolved")
        XCTAssertEqual(candidate.confirmationOperationID, operation)
        XCTAssertEqual(candidate.revision, 1)
        XCTAssertEqual(record.revision, 1)
        XCTAssertEqual(record.statusRaw, "analyzed")
        XCTAssertEqual(snapshot.occurrences.count, 1)
        XCTAssertEqual(snapshot.occurrences[0].sourceRecordID, record.id)
        XCTAssertEqual(snapshot.occurrences[0].rawTextSnapshot, record.rawText)
        XCTAssertEqual(snapshot.occurrences[0].occurredAt, record.createdAt)
        XCTAssertEqual(snapshot.occurrences[0].createdAt, Support.now)
        XCTAssertTrue(snapshot.courseLinks.contains { $0.termID == term.id && $0.courseID == record.courseID })
        XCTAssertTrue(snapshot.lookupEvents.isEmpty)
    }

    func testLinkingCandidatePreservesExistingDefinitionAndReviewState() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let candidate = try Support.candidate("quick", in: container)
        let term = try Support.term("quick", in: container)
        var expected = WordNoteSnapshotPayload.Term(term)
        expected.updatedAt = Support.now
        candidate.chineseMeaning = "Do not overwrite the existing meaning"
        try container.mainContext.save()
        _ = try service.confirmCandidate(candidate.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: UUID(), target: .linkExisting(termID: term.id, expectedRevision: 0), at: Support.now)
        XCTAssertEqual(WordNoteSnapshotPayload.Term(term), expected)
        XCTAssertEqual(term.revision, 1)
        let snapshot = try Support.snapshot(container)
        XCTAssertEqual(snapshot.content.terms.count, 4)
        XCTAssertEqual(snapshot.occurrences.count, 1)
        XCTAssertEqual(snapshot.courseLinks.count, 4)
        XCTAssertTrue(snapshot.lookupEvents.isEmpty)
    }

    func testLinkingDoesNotRequireUnusedCandidateDefinition() throws {
        let container = try Support.container()
        let candidate = try Support.candidate("quick", in: container)
        candidate.chineseMeaning = nil
        candidate.englishDefinition = nil
        try container.mainContext.save()
        let term = try Support.term("quick", in: container)
        let service = try WordNoteV2ContentService(container: container)
        XCTAssertNoThrow(try service.confirmCandidate(candidate.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: UUID(), target: .linkExisting(termID: term.id, expectedRevision: 0), at: Support.now))
        XCTAssertEqual(candidate.savedTermID, term.id)
        XCTAssertNoThrow(try Support.snapshot(container))
    }

    func testCompletedConfirmationReplaySurvivesRestoreAndIgnoresOldRevisions() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let candidate = try Support.candidate("throughput", in: container)
        let candidateID = candidate.id
        let operation = UUID()
        let first = try service.confirmCandidate(candidateID, expectedRevision: 0, expectedRecordRevision: 0, operationID: operation, target: .createNew, at: Support.now)
        let before = try Support.snapshot(container)
        let restored = try Support.container(populated: false)
        try before.populateEmptyStore(restored.mainContext)
        let other = try WordNoteV2ContentService(container: restored)
        let replay = try other.confirmCandidate(candidateID, expectedRevision: 0, expectedRecordRevision: 0, operationID: operation, target: .createNew, at: Support.now.addingTimeInterval(10))
        XCTAssertEqual(first, replay)
        XCTAssertEqual(try Support.snapshot(restored), before)
        XCTAssertThrowsError(try other.confirmCandidate(candidateID, expectedRevision: 1, expectedRecordRevision: 1, operationID: UUID(), target: .createNew, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV2ContentError, .candidateAlreadyHandled)
        }
    }

    func testMultipleCandidatesForSameCaptureAndTermDoNotDuplicateOrigin() throws {
        let container = try Support.container()
        let first = try Support.candidate("quick", in: container)
        let duplicate = WordNoteSchemaV2.CandidateTermModel(inputRecordID: first.inputRecordID, term: "quick", termType: .word, needToLearn: true, importance: .medium, category: .general, chineseMeaning: "快的")
        duplicate.analysisGeneration = first.analysisGeneration
        container.mainContext.insert(duplicate)
        try container.mainContext.save()
        let service = try WordNoteV2ContentService(container: container)
        let term = try Support.term("quick", in: container)
        _ = try service.confirmCandidate(first.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: UUID(), target: .linkExisting(termID: term.id, expectedRevision: 0), at: Support.now)
        _ = try service.confirmCandidate(duplicate.id, expectedRevision: 0, expectedRecordRevision: 1, operationID: UUID(), target: .linkExisting(termID: term.id, expectedRevision: 1), at: Support.now)
        let snapshot = try Support.snapshot(container)
        XCTAssertEqual(snapshot.occurrences.count, 1)
        XCTAssertEqual(term.revision, 1)
        XCTAssertTrue(snapshot.lookupEvents.isEmpty)
        XCTAssertEqual(try Support.record(first.inputRecordID, in: container).revision, 2)
    }

    func testCandidateAndRecordAndTargetRevisionsAreCheckedBeforeWriting() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let candidate = try Support.candidate("quick", in: container)
        let term = try Support.term("quick", in: container)
        let before = try Support.snapshot(container)
        XCTAssertThrowsError(try service.confirmCandidate(candidate.id, expectedRevision: 1, expectedRecordRevision: 0, operationID: UUID(), target: .linkExisting(termID: term.id, expectedRevision: 0), at: Support.now))
        XCTAssertThrowsError(try service.confirmCandidate(candidate.id, expectedRevision: 0, expectedRecordRevision: 1, operationID: UUID(), target: .linkExisting(termID: term.id, expectedRevision: 0), at: Support.now))
        XCTAssertThrowsError(try service.confirmCandidate(candidate.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: UUID(), target: .linkExisting(termID: term.id, expectedRevision: 1), at: Support.now))
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testConfirmationRejectsReanalysisAndStaleCandidateGeneration() throws {
        let container = try Support.container()
        let candidate = try Support.candidate("throughput", in: container)
        let record = try Support.record(candidate.inputRecordID, in: container)
        let service = try WordNoteV2ContentService(container: container)
        record.analysisGeneration += 1
        try container.mainContext.save()
        let stale = try Support.snapshot(container)
        XCTAssertThrowsError(try service.confirmCandidate(candidate.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: UUID(), target: .createNew, at: Support.now))
        XCTAssertEqual(try Support.snapshot(container), stale)
        candidate.analysisGeneration = record.analysisGeneration
        record.queueStateRaw = "running"
        record.attemptID = UUID()
        try container.mainContext.save()
        let running = try Support.snapshot(container)
        XCTAssertThrowsError(try service.confirmCandidate(candidate.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: UUID(), target: .createNew, at: Support.now))
        XCTAssertEqual(try Support.snapshot(container), running)
    }

    func testSaveFailureRollsBackNewAndLinkedConfirmationCompletely() throws {
        for name in ["quick", "throughput"] {
            let container = try Support.container()
            let failing = try WordNoteV2ContentService(container: container, save: { _ in throw Support.Failure.save })
            let candidate = try Support.candidate(name, in: container)
            let target: WordNoteV2ConfirmationTarget = name == "quick"
                ? .linkExisting(termID: try Support.term("quick", in: container).id, expectedRevision: 0) : .createNew
            let before = try Support.snapshot(container)
            XCTAssertThrowsError(try failing.confirmCandidate(candidate.id, expectedRevision: 0, expectedRecordRevision: 0, operationID: UUID(), target: target, at: Support.now)) {
                XCTAssertEqual($0 as? Support.Failure, .save)
            }
            XCTAssertEqual(try Support.snapshot(container), before)
            XCTAssertFalse(container.mainContext.hasChanges)
        }
    }

    func testManualCreationPreservesEnglishSubjectAndFloatingCaptureOrigin() throws {
        let container = try Support.container(populated: false)
        let service = try WordNoteV2ContentService(container: container)
        let result = try service.capture(.init(rawText: "過擬合", intent: .chineseToEnglish, capturedVia: .floatingQuickAdd), analyze: false, at: Support.now)
        let recordID = try Support.inputID(result)
        let created = try service.createManualTerm(sourceRecordID: recordID, expectedRecordRevision: 0, termText: "overfitting", chineseMeaning: "過擬合", englishDefinition: nil, at: Support.now)
        let term = try Support.term("overfitting", in: container)
        XCTAssertEqual(term.id, created.id)
        XCTAssertEqual(term.contextSentence, "過擬合")
        XCTAssertEqual(term.term, "overfitting")
        let snapshot = try Support.snapshot(container)
        XCTAssertEqual(snapshot.recordStates[0].capturedViaRaw, "floatingQuickAdd")
        XCTAssertEqual(snapshot.occurrences[0].capturedViaRaw, "floatingQuickAdd")
        XCTAssertFalse(snapshot.occurrences[0].legacy)
        XCTAssertEqual(snapshot.content.inputRecords[0].statusRaw, "completed")
        let restored = try Support.container(populated: false)
        try snapshot.populateEmptyStore(restored.mainContext)
        XCTAssertEqual(try Support.snapshot(restored), snapshot)
    }

    func testManualCreationUsesFrozenDirectionAndRejectsNonEnglishSubjects() throws {
        let container = try Support.container(populated: false)
        let service = try WordNoteV2ContentService(container: container)
        let result = try service.capture(.init(rawText: "Latin input", intent: .chineseToEnglish), analyze: false, at: Support.now)
        let recordID = try Support.inputID(result)
        let before = try Support.snapshot(container)
        XCTAssertThrowsError(try service.createManualTerm(sourceRecordID: recordID, expectedRecordRevision: 0, termText: "英文主體", chineseMeaning: "釋義", englishDefinition: nil, at: Support.now))
        XCTAssertThrowsError(try service.createManualTerm(sourceRecordID: recordID, expectedRecordRevision: 0, termText: "concept", chineseMeaning: nil, englishDefinition: "An idea.", at: Support.now)) {
            XCTAssertEqual($0 as? VocabularyServiceError, .chineseMeaningRequired("concept"))
        }
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testManualCreationFailureRollsBackTermAndSourceCompletion() throws {
        let container = try Support.container(populated: false)
        let service = try WordNoteV2ContentService(container: container)
        let source = try service.capture(.init(rawText: "new concept"), analyze: false, at: Support.now)
        let before = try Support.snapshot(container)
        let failing = try WordNoteV2ContentService(container: container, save: { _ in throw Support.Failure.save })
        XCTAssertThrowsError(try failing.createManualTerm(sourceRecordID: Support.inputID(source), expectedRecordRevision: 0, termText: "concept", chineseMeaning: "概念", englishDefinition: nil, at: Support.now)) {
            XCTAssertEqual($0 as? Support.Failure, .save)
        }
        XCTAssertEqual(try Support.snapshot(container), before)
    }
}
