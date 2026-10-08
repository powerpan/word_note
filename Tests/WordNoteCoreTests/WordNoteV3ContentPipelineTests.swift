import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3ContentPipelineTests: XCTestCase {
    private typealias S = WordNoteV3ServiceTestSupport
    private typealias Term = WordNoteSchemaV3.TermModel
    private typealias Record = WordNoteSchemaV3.InputRecordModel
    private let now = WordNoteV3ServiceTestSupport.now

    func testBilingualCaptureToConfirmationReviewAndBackupPreservesContentAndNewSemantics() throws {
        let container = try S.container(populated: false)
        let service = try WordNoteV3ContentService(container: container)
        let course = try service.createCourse(courseName: "Synthetic Course", at: now)
        let english = try analyze("Measure precision before changing the classifier.", term: "precision", course: course.id, service: service)
        let chinese = try analyze("準確度", term: "accuracy", course: course.id, service: service, intent: .chineseToEnglish)
        let raw = try S.fullSnapshot(container).content.content.inputRecords
        XCTAssertTrue(try S.fullSnapshot(container).cards.isEmpty)
        XCTAssertTrue(try S.fullSnapshot(container).content.content.terms.isEmpty)
        let plan = try S.plan(["precision", "accuracy"], container: container, service: service)
        let confirmed = try service.commitConfirmationPlan(plan, at: now)
        let saved = try S.fullSnapshot(container)
        XCTAssertEqual(Set(saved.content.content.terms.map(\.term)), ["precision", "accuracy"])
        XCTAssertEqual(saved.cards.count, 2)
        XCTAssertEqual(saved.content.occurrences.count, 2)
        XCTAssertEqual(saved.content.courseLinks.count, 2)
        XCTAssertEqual(Set(saved.content.occurrences.compactMap(\.sourceRecordID)), [english, chinese])
        XCTAssertEqual(saved.content.content.inputRecords.map(\.rawText), raw.map(\.rawText))
        XCTAssertTrue(saved.content.content.inputRecords.allSatisfy { $0.statusRaw == "completed" })
        XCTAssertTrue(saved.cards.allSatisfy { $0.mode == .englishToChinese && $0.schedule.phase == .new && $0.schedule.introducedAt == nil })
        XCTAssertTrue(saved.termHistories.allSatisfy { $0.legacySnapshotAt == nil })
        for term in saved.content.content.terms { assertUnlearnedLegacy(term) }
        XCTAssertTrue(try service.commitConfirmationPlan(plan, at: now).wasAlreadyApplied)
        XCTAssertEqual(try S.fullSnapshot(container), saved)

        let termID = try XCTUnwrap(confirmed.termIDs.first)
        let term = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<Term>()).first { $0.id == termID })
        _ = try service.enableReviewDirection(termID: term.id, expectedTermRevision: term.revision, mode: .chineseToEnglish,
                                               studyTimeZoneID: "Asia/Hong_Kong", at: now)
        let review = try WordNoteV3ReviewService(container: container)
        let session = try review.startSession(scope: V3SessionTestSupport.scope(newCards: true, mode: .chineseToEnglish), at: now)
        let lease = try review.acquireLease(sessionID: session.session.id, ownerID: UUID())
        let presented = try XCTUnwrap(review.presentNextCard(lease: lease, expectedRevision: session.session.revision, at: now))
        XCTAssertEqual(presented.card.termID, termID)
        XCTAssertThrowsError(try review.revealedQuestion(lease: lease))
        _ = try review.revealAnswer(presented, lease: lease, at: now)
        XCTAssertEqual(try review.revealedQuestion(lease: lease, typedAnswer: term.term).assessment, .matchesSavedAnswer)
        _ = try review.recordFeedback(review.previewFeedback(.good, lease: lease, at: now), actionID: UUID(), lease: lease, at: now)
        let reviewed = try S.fullSnapshot(container)
        XCTAssertEqual(reviewed.content.content.reviewEvents.count, 1)
        XCTAssertEqual(reviewed.eventStates.first?.feedbackSemanticsVersion, 2)
        XCTAssertEqual(reviewed.cards.first { $0.id == presented.card.id }?.schedule.phase, .review)
        for term in reviewed.content.content.terms { assertUnlearnedLegacy(term) }
        let sibling = try XCTUnwrap(reviewed.cards.first { $0.termID == termID && $0.mode == .englishToChinese })
        XCTAssertEqual(sibling.schedule.phase, .new)
        XCTAssertNil(sibling.schedule.introducedAt)
        XCTAssertNotNil(sibling.schedule.buriedUntil)
        let decoded = try WordNoteSnapshotV3Codec.decode(WordNoteSnapshotV3Codec.encode(reviewed, kind: .manual)).payload
        let restored = try S.container(populated: false)
        try decoded.populateEmptyStore(restored.mainContext)
        XCTAssertEqual(try S.fullSnapshot(restored), reviewed)
    }

    func testEveryNewTermPathCreatesOneIndependentCardAndUndoRemovesIt() throws {
        for path in NewTermPath.allCases {
            let container = try S.container(populated: false)
            let history = try WordNoteV3UndoHistory(container: container)
            let service = try WordNoteV3ContentService(container: container, undoHistory: history)
            let source = try source(for: path, service: service)
            let before = try S.fullSnapshot(container)
            let termID = try create(path, sourceID: source, container: container, service: service)
            let added = try S.fullSnapshot(container)
            XCTAssertEqual(added.cards.count, 1)
            XCTAssertEqual(added.cards.first?.termID, termID)
            XCTAssertEqual(added.cards.first?.schedule, ReviewCardSchedule())
            assertUnlearnedLegacy(try XCTUnwrap(added.content.content.terms.first))
            try history.undo(at: now.addingTimeInterval(1))
            let undone = try S.fullSnapshot(container)
            XCTAssertTrue(undone.cards.isEmpty)
            XCTAssertTrue(undone.content.content.terms.isEmpty)
            XCTAssertEqual(undone.content.occurrences, before.content.occurrences)
            XCTAssertEqual(undone.content.content.candidates.map(\.statusRaw), before.content.content.candidates.map(\.statusRaw))
            XCTAssertEqual(undone.content.content.inputRecords.map(\.statusRaw), before.content.content.inputRecords.map(\.statusRaw))
            XCTAssertFalse(history.canUndo)
        }
    }

    func testNewTermSaveFailureRollsBackAllElevenEntityTypesAndPreservesPreviousUndo() throws {
        for path in NewTermPath.allCases {
            let container = try S.container(populated: false)
            let history = try WordNoteV3UndoHistory(container: container)
            let service = try WordNoteV3ContentService(container: container, undoHistory: history)
            let source = try source(for: path, service: service)
            _ = try service.createCourse(courseName: "Prior receipt", at: now)
            let receipt = history.operationID
            let before = try S.fullSnapshot(container)
            let failing = try WordNoteV3ContentService(container: container, undoHistory: history, beforeSave: { _ in throw S.Failure.save })
            XCTAssertThrowsError(try create(path, sourceID: source, container: container, service: failing)) {
                XCTAssertEqual($0 as? S.Failure, .save)
            }
            XCTAssertEqual(try S.fullSnapshot(container), before)
            XCTAssertEqual(history.operationID, receipt)
            XCTAssertFalse(container.mainContext.hasChanges)
            _ = try create(path, sourceID: source, container: container, service: service)
            XCTAssertEqual(try S.fullSnapshot(container).cards.count, 1)
        }
    }

    func testManualSourceRejectsIgnoredOrAlreadyHandledRecords() throws {
        for status in [InputRecordStatus.ignored, .completed] {
            let container = try S.container(populated: false)
            let service = try WordNoteV3ContentService(container: container)
            let id = try S.inputID(service.capture(.init(rawText: "precision"), analyze: false, at: now))
            let record = try S.record(id, in: container)
            record.status = status
            try container.mainContext.save()
            let before = try S.fullSnapshot(container)
            XCTAssertNotNil(try service.manualSourceDraftVersion(id).blockingMessage)
            XCTAssertThrowsError(try create(.manual, sourceID: id, container: container, service: service)) {
                XCTAssertEqual($0 as? WordNoteV3ContentError, .invalidState)
            }
            XCTAssertEqual(try S.fullSnapshot(container), before)
        }
    }

    func testAttemptRejectsMissedRevisionContentMutationButCourseRenameKeepsFrozenRequest() throws {
        for change in 0..<4 {
            let container = try S.container(populated: false)
            let service = try WordNoteV3ContentService(container: container)
            let course = try service.createCourse(courseName: "Original", at: now)
            let id = try S.inputID(service.capture(.init(rawText: "precision", courseID: course.id), at: now))
            let attempt = try service.beginAnalysis(id, expectedRevision: 0, at: now)
            let record = try S.record(id, in: container)
            switch change {
            case 0: record.note = "New context"
            case 1: record.sourceType = .paper
            case 2: record.courseID = nil
            default:
                try service.updateCourse(course.id, expectedRevision: 0, courseName: "Renamed", courseCode: nil,
                    instructor: nil, semester: nil, description: nil, at: now)
            }
            try container.mainContext.save()
            let before = try S.fullSnapshot(container)
            XCTAssertEqual(attempt.request.courseName, "Original")
            if change == 3 {
                _ = try service.completeAnalysis(attempt, result: AnalysisTestValues.result(), at: now)
                XCTAssertEqual(try S.fullSnapshot(container).content.content.candidates.count, 1)
            } else {
                XCTAssertThrowsError(try service.completeAnalysis(attempt, result: AnalysisTestValues.result(), at: now)) {
                    XCTAssertEqual($0 as? WordNoteV3AnalysisError, .staleAttempt)
                }
                XCTAssertThrowsError(try service.failAnalysis(attempt, error: AIAnalysisError.timeout, at: now))
                XCTAssertEqual(try S.fullSnapshot(container), before)
            }
        }
    }

    func testEditingAndOrganizationUndoNeverChangeCardLearningOrLegacyCounters() throws {
        let container = try S.container()
        let history = try WordNoteV3UndoHistory(container: container)
        let service = try WordNoteV3ContentService(container: container, undoHistory: history)
        let term = try S.term("quick", in: container)
        let before = try S.fullSnapshot(container)
        let originalMeaning = term.chineseMeaning
        try edit(term, meaning: "Updated definition", service: service)
        XCTAssertEqual(try S.fullSnapshot(container).cards, before.cards)
        XCTAssertEqual(try S.fullSnapshot(container).termHistories, before.termHistories)
        try history.undo(at: now)
        XCTAssertEqual(term.chineseMeaning, originalMeaning)
        XCTAssertEqual(try S.fullSnapshot(container).cards, before.cards)
        let course = try service.createCourse(courseName: "New course", at: now)
        var changes = WordNoteV2OrganizationChanges()
        changes.coursesToAdd = [course.id]
        changes.tagsToAdd = ["Exam"]
        let baseline = try S.fullSnapshot(container)
        let plan = try service.makeOrganizationPlan(termIDs: [term.id], changes: changes)
        _ = try service.commitOrganizationPlan(plan, at: now)
        XCTAssertEqual(term.tags, (baseline.content.content.terms.first { $0.id == term.id }?.tags ?? []) + ["Exam"])
        try history.undo(at: now)
        let undone = try S.fullSnapshot(container)
        XCTAssertEqual(undone.cards, baseline.cards)
        XCTAssertEqual(undone.termHistories, baseline.termHistories)
        XCTAssertEqual(undone.eventStates, baseline.eventStates)
        XCTAssertEqual(undone.content.courseLinks, baseline.content.courseLinks)
        XCTAssertEqual(term.tags, baseline.content.content.terms.first { $0.id == term.id }?.tags)
    }

    func testContentEditorRejectsLegacyMasteryChangesAtomically() throws {
        let container = try S.container()
        let service = try WordNoteV3ContentService(container: container)
        let term = try S.term("quick", in: container)
        let before = try S.fullSnapshot(container)
        let different: MasteryLevel = term.masteryLevel == .new ? .mastered : .new
        XCTAssertThrowsError(try edit(term, meaning: "Should not save", service: service, mastery: different)) {
            XCTAssertEqual($0 as? WordNoteV3ContentError, .reviewStateReadOnly)
        }
        XCTAssertEqual(try S.fullSnapshot(container), before)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testUndoNewTermIsBlockedByEnrollmentRevealAnswerLookupOrAdditionalDirection() throws {
        for mutation in 0..<5 {
            let container = try S.container(populated: false)
            let history = try WordNoteV3UndoHistory(container: container)
            let service = try WordNoteV3ContentService(container: container, undoHistory: history)
            let source = try self.source(for: .single, service: service)
            let termID = try create(.single, sourceID: source, container: container, service: service)
            if mutation < 3 {
                let review = try WordNoteV3ReviewService(container: container)
                let session = try review.startSession(scope: V3SessionTestSupport.scope(newCards: true), at: now)
                if mutation > 0 {
                    let lease = try review.acquireLease(sessionID: session.session.id, ownerID: UUID())
                    let current = try XCTUnwrap(review.presentNextCard(lease: lease, expectedRevision: session.session.revision, at: now))
                    _ = try review.revealAnswer(current, lease: lease, at: now)
                    if mutation == 2 {
                        _ = try review.recordFeedback(review.previewFeedback(.again, lease: lease, at: now), actionID: UUID(), lease: lease, at: now)
                    }
                }
            } else if mutation == 3 {
                _ = try service.capture(.init(rawText: "PRECISION"), at: now)
            } else {
                _ = try service.enableReviewDirection(termID: termID, expectedTermRevision: 0, mode: .chineseToEnglish,
                    studyTimeZoneID: "Asia/Hong_Kong", at: now)
            }
            let before = try S.fullSnapshot(container)
            XCTAssertThrowsError(try history.undo(at: now)) {
                XCTAssertEqual($0 as? WordNoteV3UndoError, .changedSinceSave)
            }
            XCTAssertEqual(try S.fullSnapshot(container), before)
            XCTAssertFalse(history.canUndo)
        }
    }

    func testUndoSourceOrCourseDoesNotRemoveNewReviewDependencies() throws {
        let container = try S.container(populated: false)
        let history = try WordNoteV3UndoHistory(container: container)
        let service = try WordNoteV3ContentService(container: container, undoHistory: history)
        _ = try analyze("Measure precision before training.", term: "precision", service: service)
        let plan = try S.plan(["precision"], container: container, service: service)
        let result = try service.commitConfirmationPlan(plan, at: now)
        let termID = try XCTUnwrap(result.termIDs.first)
        let occurrence = try XCTUnwrap(S.fullSnapshot(container).content.occurrences.first)
        let range = try XCTUnwrap(service.clozeSuggestions(termID: termID, occurrenceID: occurrence.id).first)
        let draft = try service.previewClozeCard(termID: termID, occurrenceID: occurrence.id, selectedRange: range)
        _ = try service.createClozeCard(draft, studyTimeZoneID: "Asia/Hong_Kong", at: now)
        let before = try S.fullSnapshot(container)
        XCTAssertThrowsError(try history.undo(at: now)) { XCTAssertEqual($0 as? WordNoteV3UndoError, .changedSinceSave) }
        XCTAssertEqual(try S.fullSnapshot(container), before)

        let course = try service.createCourse(courseName: "Frozen session course", at: now)
        let otherWriter = try WordNoteV3ContentService(container: container)
        let term = try S.term("precision", in: container)
        _ = try otherWriter.setCourseMembership(termID: termID, courseID: course.id, included: true,
            expectedTermRevision: term.revision, at: now)
        let review = try WordNoteV3ReviewService(container: container)
        _ = try review.startSession(scope: V3SessionTestSupport.scope(newCards: true, courseID: course.id), at: now)
        _ = try otherWriter.setCourseMembership(termID: termID, courseID: course.id, included: false,
            expectedTermRevision: term.revision, at: now)
        XCTAssertFalse(try service.courseUsage(course.id).isInUse)
        let withSession = try S.fullSnapshot(container)
        XCTAssertThrowsError(try history.undo(at: now)) { XCTAssertEqual($0 as? WordNoteV3UndoError, .changedSinceSave) }
        XCTAssertEqual(try S.fullSnapshot(container), withSession)
    }

    func testReviewingUnrelatedTermDoesNotBlockContentUndoOrRewindReview() throws {
        let container = try S.container(populated: false)
        let history = try WordNoteV3UndoHistory(container: container)
        let service = try WordNoteV3ContentService(container: container, undoHistory: history)
        _ = try analyze("precision", term: "precision", service: service)
        _ = try analyze("accuracy", term: "accuracy", service: service)
        _ = try service.commitConfirmationPlan(S.plan(["precision", "accuracy"], container: container, service: service), at: now)
        let first = try S.term("precision", in: container)
        let second = try S.term("accuracy", in: container)
        _ = try service.enableReviewDirection(termID: second.id, expectedTermRevision: second.revision, mode: .chineseToEnglish,
            studyTimeZoneID: "Asia/Hong_Kong", at: now)
        let original = first.chineseMeaning
        try edit(first, meaning: "Edited temporarily", service: service)
        let review = try WordNoteV3ReviewService(container: container)
        _ = try V3SessionTestSupport.introduce(review, at: now,
            scope: V3SessionTestSupport.scope(newCards: true, mode: .chineseToEnglish))
        let reviewed = try S.fullSnapshot(container)
        try history.undo(at: now)
        let undone = try S.fullSnapshot(container)
        XCTAssertEqual(first.chineseMeaning, original)
        XCTAssertEqual(undone.cards, reviewed.cards)
        XCTAssertEqual(undone.sessions, reviewed.sessions)
        XCTAssertEqual(undone.sessionItems, reviewed.sessionItems)
        XCTAssertEqual(undone.eventStates, reviewed.eventStates)
    }

    func testEditingAnExposedAnswerInvalidatesOldFeedbackWithoutLosingTheEdit() throws {
        let container = try S.container(populated: false)
        let service = try WordNoteV3ContentService(container: container)
        let source = try self.source(for: .single, service: service)
        _ = try create(.single, sourceID: source, container: container, service: service)
        let review = try WordNoteV3ReviewService(container: container)
        let session = try review.startSession(scope: V3SessionTestSupport.scope(newCards: true), at: now)
        let lease = try review.acquireLease(sessionID: session.session.id, ownerID: UUID())
        let current = try XCTUnwrap(review.presentNextCard(lease: lease, expectedRevision: session.session.revision, at: now))
        _ = try review.revealAnswer(current, lease: lease, at: now)
        let feedback = try review.previewFeedback(.good, lease: lease, at: now)
        let term = try S.term("precision", in: container)
        try edit(term, meaning: "Corrected definition", service: service)
        let before = try S.fullSnapshot(container)
        XCTAssertThrowsError(try review.recordFeedback(feedback, actionID: UUID(), lease: lease, at: now))
        XCTAssertEqual(try S.fullSnapshot(container), before)
        XCTAssertEqual(term.chineseMeaning, "Corrected definition")
        XCTAssertTrue(before.content.content.reviewEvents.isEmpty)
    }

    func testUndoAndContentServicesRejectWrongSchemaAndDifferentContainer() throws {
        let old = try WordNoteV2ServiceTestSupport.container(populated: false)
        XCTAssertThrowsError(try WordNoteV3ContentService(container: old))
        XCTAssertThrowsError(try WordNoteV3UndoHistory(container: old))
        let a = try S.container(populated: false), b = try S.container(populated: false)
        let history = try WordNoteV3UndoHistory(container: a)
        XCTAssertThrowsError(try WordNoteV3ContentService(container: b, undoHistory: history)) {
            XCTAssertEqual($0 as? WordNoteV3UndoError, .differentStore)
        }
    }

    private enum NewTermPath: CaseIterable { case manual, single, batch }

    private func source(for path: NewTermPath, service: WordNoteV3ContentService) throws -> UUID {
        if path == .manual { return try S.inputID(service.capture(.init(rawText: "precision"), analyze: false, at: now)) }
        return try analyze("precision", term: "precision", service: service)
    }

    private func create(_ path: NewTermPath, sourceID: UUID, container: ModelContainer, service: WordNoteV3ContentService) throws -> UUID {
        let record = try S.record(sourceID, in: container)
        switch path {
        case .manual:
            return try service.createManualTerm(sourceRecordID: sourceID, expectedRecordRevision: record.revision, termText: "precision",
                chineseMeaning: "精度", englishDefinition: nil, at: now).id
        case .single:
            let candidate = try S.candidate("precision", in: container)
            return try service.confirmCandidate(candidate.id, expectedRevision: candidate.revision, expectedRecordRevision: record.revision,
                operationID: UUID(), target: .createNew, at: now).id
        case .batch:
            let result = try service.commitConfirmationPlan(S.plan(["precision"], container: container, service: service), at: now)
            return try XCTUnwrap(result.termIDs.first)
        }
    }

    @discardableResult
    private func analyze(_ text: String, term: String, course: UUID? = nil, service: WordNoteV3ContentService,
                         intent: LookupIntent = .auto) throws -> UUID {
        let id = try S.inputID(service.capture(.init(rawText: text, courseID: course, intent: intent), at: now))
        let attempt = try service.beginAnalysis(id, expectedRevision: 0, at: now)
        _ = try service.completeAnalysis(attempt, result: AnalysisTestValues.result(candidates: [AnalysisTestValues.candidate(term)]), at: now)
        return id
    }

    private func edit(_ term: Term, meaning: String, service: WordNoteV3ContentService, mastery: MasteryLevel? = nil) throws {
        let draft = try service.termDraftVersion(term.id)
        try service.updateTerm(term.id, expectedRevision: term.revision, termText: term.term, termType: term.termType,
            chineseMeaning: meaning, englishDefinition: term.englishDefinition, aiContextExplanation: term.aiContextExplanation,
            exampleSentence: term.exampleSentence, contextSentence: term.contextSentence, courseIDs: draft.value.courseIDs,
            sourceType: term.sourceType, category: term.category, importance: term.importance, masteryLevel: mastery ?? term.masteryLevel, at: now)
    }

    private func assertUnlearnedLegacy(_ term: WordNoteSnapshotPayload.Term, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(term.reviewCount, 0, file: file, line: line)
        XCTAssertEqual(term.wrongCount, 0, file: file, line: line)
        XCTAssertEqual(term.duplicateHitCount, 0, file: file, line: line)
        XCTAssertNil(term.lastReviewedAt, file: file, line: line)
        XCTAssertNil(term.nextReviewAt, file: file, line: line)
    }
}
