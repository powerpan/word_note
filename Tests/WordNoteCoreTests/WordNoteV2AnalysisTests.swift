import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2AnalysisTests: XCTestCase {
    private typealias Support = WordNoteV2ServiceTestSupport

    func testBeginFreezesRequestAndSavesRunningBeforeNetwork() throws {
        let container = try Support.container(populated: false)
        var saves = 0
        let service = try WordNoteV2ContentService(container: container, save: { saves += 1; try $0.save() })
        let course = try service.createCourse(courseName: "Synthetic Course", at: Support.now)
        let result = try service.capture(.init(rawText: "精度", courseID: course.id, sourceType: .paper, note: "source", intent: .englishToChinese), at: Support.now)
        let id = try Support.inputID(result)
        let before = saves
        let attempt = try service.beginAnalysis(id, expectedRevision: 0, at: Support.now)
        XCTAssertEqual(saves, before + 1)
        XCTAssertEqual(attempt.request.lookupDirection, .englishToChinese)
        XCTAssertEqual(attempt.request.courseName, "Synthetic Course")
        XCTAssertEqual(attempt.request.sourceType, .paper)
        XCTAssertEqual(attempt.request.userNote, "source")
        XCTAssertEqual(attempt.request.rawText, "精度")
        let record = try Support.record(id, in: container)
        XCTAssertEqual(record.queueStateRaw, "running")
        XCTAssertEqual(record.status, .draft)
        XCTAssertEqual(record.attemptID, attempt.attemptID)
        XCTAssertEqual(record.revision, attempt.revision)
        try Support.snapshot(container).validate()
        XCTAssertThrowsError(try service.beginAnalysis(id, expectedRevision: record.revision, at: Support.now))
    }

    func testCompleteIsAtomicAndRepeatedCallbackCannotWriteTwice() throws {
        let container = try Support.container(populated: false)
        var saves = 0
        let service = try WordNoteV2ContentService(container: container, save: { saves += 1; try $0.save() })
        let attempt = try begin(service)
        let before = saves
        let preview = try service.completeAnalysis(attempt, result: AnalysisTestValues.result(), at: Support.now)
        XCTAssertEqual(saves, before + 1)
        XCTAssertEqual(preview.candidates.first?.term, "precision")
        let completed = try Support.snapshot(container)
        XCTAssertEqual(completed.content.candidates.count, 1)
        XCTAssertEqual(completed.content.inputRecords[0].statusRaw, "analyzed")
        XCTAssertEqual(completed.recordStates[0].queueStateRaw, "none")
        XCTAssertNil(completed.recordStates[0].attemptID)
        XCTAssertEqual(completed.candidateStates[0].analysisGeneration, attempt.generation)
        XCTAssertThrowsError(try service.completeAnalysis(attempt, result: AnalysisTestValues.result(), at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV2AnalysisError, .staleAttempt)
        }
        XCTAssertThrowsError(try service.failAnalysis(attempt, error: AIAnalysisError.timeout, at: Support.now))
        XCTAssertEqual(try Support.snapshot(container), completed)
        XCTAssertEqual(saves, before + 1)
    }

    func testCompletionSaveFailureRollsBackCandidatesAndRecord() throws {
        let container = try Support.container(populated: false)
        var fail = false
        let service = try WordNoteV2ContentService(container: container, save: {
            if fail { throw Support.Failure.save }
            try $0.save()
        })
        let attempt = try begin(service)
        let before = try Support.snapshot(container)
        fail = true
        XCTAssertThrowsError(try service.completeAnalysis(attempt, result: AnalysisTestValues.result(), at: Support.now))
        XCTAssertFalse(container.mainContext.hasChanges)
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testReanalysisKeepsManualContentSavedLinksAndIgnoredCandidates() throws {
        let container = try Support.container(populated: false)
        let service = try WordNoteV2ContentService(container: container)
        let attempt = try begin(service)
        let candidates = [AnalysisTestValues.candidate("precision"), AnalysisTestValues.candidate("accuracy"), AnalysisTestValues.candidate("recall")]
        try service.completeAnalysis(attempt, result: AnalysisTestValues.result(candidates: candidates), at: Support.now)
        let record = try Support.record(attempt.recordID, in: container)
        let saved = try Support.candidate("precision", in: container)
        let target = try service.confirmCandidate(saved.id, expectedRevision: saved.revision, expectedRecordRevision: record.revision,
                                                  operationID: UUID(), target: .createNew, at: Support.now)
        let pending = try Support.candidate("accuracy", in: container)
        pending.chineseMeaning = "人工保留的內容"
        pending.revision += 1
        let ignored = try Support.candidate("recall", in: container)
        ignored.status = .ignored
        ignored.revision += 1
        try container.mainContext.save()
        let savedBefore = try Support.snapshot(container).candidateStates.first { $0.id == saved.id }
        _ = try service.queueAnalysis(record.id, expectedRevision: record.revision, at: Support.now)
        let next = try service.beginAnalysis(record.id, expectedRevision: record.revision, at: Support.now)
        let preview = try service.completeAnalysis(next, result: AnalysisTestValues.result(candidates: candidates + [AnalysisTestValues.candidate("metric")]), at: Support.now)
        XCTAssertEqual(pending.chineseMeaning, "人工保留的內容")
        XCTAssertEqual(pending.analysisGeneration, next.generation)
        XCTAssertEqual(saved.savedTermID, target.id)
        XCTAssertEqual(ignored.status, .ignored)
        XCTAssertFalse(preview.candidates.contains { $0.term == "recall" })
        XCTAssertEqual(preview.candidates.first { $0.term == "accuracy" }?.chineseMeaning, "人工保留的內容")
        let after = try Support.snapshot(container)
        XCTAssertEqual(after.content.candidates.count, 4)
        XCTAssertEqual(after.content.terms.count, 1)
        XCTAssertEqual(after.candidateStates.first { $0.id == saved.id }, savedBefore)
        _ = try service.confirmCandidate(pending.id, expectedRevision: pending.revision, expectedRecordRevision: record.revision,
                                         operationID: UUID(), target: .createNew, at: Support.now)
    }

    func testDeletedSavedTargetIsNotRecreatedByReanalysis() throws {
        let container = try Support.container(populated: false)
        let service = try WordNoteV2ContentService(container: container)
        let attempt = try begin(service)
        try service.completeAnalysis(attempt, result: AnalysisTestValues.result(), at: Support.now)
        let record = try Support.record(attempt.recordID, in: container)
        let candidate = try Support.candidate("precision", in: container)
        let target = try service.confirmCandidate(candidate.id, expectedRevision: candidate.revision, expectedRecordRevision: record.revision,
                                                  operationID: UUID(), target: .createNew, at: Support.now)
        try service.deleteTerm(target.id, expectedRevision: target.revision, at: Support.now)
        _ = try service.queueAnalysis(record.id, expectedRevision: record.revision, at: Support.now)
        let next = try service.beginAnalysis(record.id, expectedRevision: record.revision, at: Support.now)
        try service.completeAnalysis(next, result: AnalysisTestValues.result(), at: Support.now)
        XCTAssertEqual(candidate.savedLinkStateRaw, "targetDeleted")
        XCTAssertNil(candidate.savedTermID)
        XCTAssertTrue(try Support.snapshot(container).content.terms.isEmpty)
        XCTAssertEqual(record.status, .completed)
    }

    func testFailureAndCancellationLeaveOldPendingCandidatesConfirmable() throws {
        for cancel in [false, true] {
            let container = try Support.container(populated: false)
            let service = try WordNoteV2ContentService(container: container)
            let first = try begin(service)
            try service.completeAnalysis(first, result: AnalysisTestValues.result(), at: Support.now)
            let record = try Support.record(first.recordID, in: container)
            _ = try service.queueAnalysis(record.id, expectedRevision: record.revision, at: Support.now)
            let next = try service.beginAnalysis(record.id, expectedRevision: record.revision, at: Support.now)
            if cancel { try service.cancelAnalysis(record.id, expectedRevision: record.revision, at: Support.now) }
            else { try service.failAnalysis(next, error: AIAnalysisError.invalidResponse, at: Support.now) }
            let candidate = try Support.candidate("precision", in: container)
            XCTAssertEqual(candidate.analysisGeneration, record.analysisGeneration)
            _ = try service.confirmCandidate(candidate.id, expectedRevision: candidate.revision, expectedRecordRevision: record.revision,
                                             operationID: UUID(), target: .createNew, at: Support.now)
        }
    }

    func testCancelledDeletedAndRestoredAttemptsCannotWriteBack() throws {
        for action in 0..<3 {
            let container = try Support.container(populated: false)
            let service = try WordNoteV2ContentService(container: container)
            let attempt = try begin(service)
            if action == 0 { try service.cancelAnalysis(attempt.recordID, expectedRevision: attempt.revision, at: Support.now) }
            if action == 1 { try service.deleteInputRecord(attempt.recordID, expectedRevision: attempt.revision, at: Support.now) }
            if action == 2 {
                let ticket = try WordNoteWriteGate.beginRestore(container.mainContext)
                try WordNoteWriteGate.endRestore(container.mainContext, ticket: ticket)
            }
            let before = try Support.snapshot(container)
            XCTAssertThrowsError(try service.completeAnalysis(attempt, result: AnalysisTestValues.result(), at: Support.now))
            XCTAssertThrowsError(try service.failAnalysis(attempt, error: AIAnalysisError.timeout, at: Support.now))
            XCTAssertEqual(try Support.snapshot(container), before)
        }
    }

    func testRetriesPersistBackoffAndStopAfterTwo() throws {
        let container = try Support.container(populated: false)
        let service = try WordNoteV2ContentService(container: container)
        var attempt = try begin(service)
        var time = Support.now
        for index in 0...2 {
            try service.failAnalysis(attempt, error: AIAnalysisError.timeout, at: time)
            let job = try XCTUnwrap(service.analysisJobs().first)
            XCTAssertEqual(job.state, index < 2 ? .queued : .failed)
            XCTAssertEqual(job.autoRetryCount, min(index + 1, 2))
            if index < 2 {
                let next = try XCTUnwrap(job.nextAttemptAt)
                XCTAssertEqual(next, time.addingTimeInterval(index == 0 ? 2 : 4))
                XCTAssertThrowsError(try service.beginAnalysis(job.id, expectedRevision: job.revision, at: time))
                time = next
                attempt = try service.beginAnalysis(job.id, expectedRevision: job.revision, at: time)
            }
        }
        try Support.snapshot(container).validate()
    }

    func testManualRetryAndCancelCannotBypassProviderDeadline() throws {
        for delay in [30.0, 120.0] {
            let container = try Support.container(populated: false)
            let service = try WordNoteV2ContentService(container: container)
            let attempt = try begin(service)
            let deadline = Support.now.addingTimeInterval(delay)
            try service.failAnalysis(attempt, error: AIAnalysisRetryAfterError(failure: .rateLimited, notBefore: deadline), at: Support.now)
            let record = try Support.record(attempt.recordID, in: container)
            if delay == 30 { try service.cancelAnalysis(record.id, expectedRevision: record.revision, at: Support.now) }
            XCTAssertThrowsError(try service.queueAnalysis(record.id, expectedRevision: record.revision, at: Support.now)) {
                XCTAssertEqual($0 as? WordNoteV2AnalysisError, .retryDeferred(until: deadline))
            }
            try Support.snapshot(container).validate()
            _ = try service.queueAnalysis(record.id, expectedRevision: record.revision, at: deadline)
            XCTAssertEqual(record.autoRetryCount, 0)
            XCTAssertEqual(record.queueStateRaw, "queued")
        }
    }

    func testInvalidResultCannotPartiallyReplaceData() throws {
        let container = try Support.container(populated: false)
        let service = try WordNoteV2ContentService(container: container)
        let attempt = try begin(service, rawText: "準確度")
        let before = try Support.snapshot(container)
        let invalid = [
            [AnalysisTestValues.candidate("中文主體")],
            [AnalysisTestValues.candidate("valid"), AnalysisTestValues.candidate("invalid", confidence: .nan)],
            [AnalysisTestValues.candidate("same"), AnalysisTestValues.candidate("SAME")],
            [AnalysisTestValues.candidate("word", meaning: "")],
            []
        ]
        for values in invalid {
            XCTAssertThrowsError(try service.completeAnalysis(attempt, result: AnalysisTestValues.result(candidates: values), at: Support.now)) {
                XCTAssertEqual($0 as? AIAnalysisError, .invalidResponse)
            }
            XCTAssertEqual(try Support.snapshot(container), before)
        }
    }

    func testRecoveryInvalidatesOldAttemptAndPreservesRawCapture() throws {
        let container = try Support.container(populated: false)
        let service = try WordNoteV2ContentService(container: container)
        let attempt = try begin(service)
        XCTAssertEqual(try service.recoverInterruptedAnalyses(at: Support.now), 1)
        XCTAssertEqual(try service.recoverInterruptedAnalyses(at: Support.now), 0)
        let record = try Support.record(attempt.recordID, in: container)
        XCTAssertEqual(record.rawText, attempt.request.rawText)
        XCTAssertEqual(record.queueStateRaw, "queued")
        XCTAssertNil(record.attemptID)
        XCTAssertGreaterThan(record.analysisGeneration, attempt.generation)
        XCTAssertThrowsError(try service.completeAnalysis(attempt, result: AnalysisTestValues.result(), at: Support.now))
        try Support.snapshot(container).validate()
    }

    func testUnsavedEditsAreNotRolledBackByAnalysisCallback() throws {
        let container = try Support.container(populated: false)
        let service = try WordNoteV2ContentService(container: container)
        let attempt = try begin(service)
        let record = try Support.record(attempt.recordID, in: container)
        record.note = "unsaved user edit"
        XCTAssertThrowsError(try service.completeAnalysis(attempt, result: AnalysisTestValues.result(), at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV2ContentError, .unsavedChanges)
        }
        XCTAssertEqual(record.note, "unsaved user edit")
        XCTAssertTrue(container.mainContext.hasChanges)
        container.mainContext.rollback()
    }

    func testServiceRetainsContainerForDeferredAnalysisCompletion() throws {
        var container: ModelContainer? = try Support.container(populated: false)
        weak var retained = container
        let service = try WordNoteV2ContentService(container: XCTUnwrap(container))
        let attempt = try begin(service)
        container = nil
        XCTAssertNotNil(retained)
        let preview = try service.completeAnalysis(attempt, result: AnalysisTestValues.result(), at: Support.now)
        XCTAssertEqual(preview.candidates.first?.term, "precision")
        retained = nil
    }

    private func begin(_ service: WordNoteV2ContentService, rawText: String = "precision") throws -> WordNoteV2AnalysisAttempt {
        let id = try Support.inputID(service.capture(.init(rawText: rawText), at: Support.now))
        return try service.beginAnalysis(id, expectedRevision: 0, at: Support.now)
    }
}

enum AnalysisTestValues {
    static func candidate(_ term: String, meaning: String = "測試釋義", confidence: Double = 0.9) -> AIAnalysisCandidate {
        .init(term: term, termType: .word, needToLearn: true, importance: .medium, category: .general,
              chineseMeaning: meaning, englishDefinition: "Synthetic test definition", confidence: confidence)
    }

    static func result(candidates: [AIAnalysisCandidate] = [candidate("precision")]) -> AIAnalysisResult {
        .init(inputType: .word, sentenceMeaning: nil, candidates: candidates, model: "mock", rawResponseID: nil)
    }
}
