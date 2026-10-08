import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2ConfirmationPlanTests: XCTestCase {
    private typealias Support = WordNoteV2ServiceTestSupport
    private typealias Candidate = WordNoteSchemaV2.CandidateTermModel
    private typealias Term = WordNoteSchemaV2.TermModel
    private typealias Helper = ConfirmationPlanTestSupport

    func testPreviewIsReadOnlyAndSeparatesRecordsCandidatesAndTermCounts() throws {
        let container = try Support.container()
        let history = try WordNoteV2UndoHistory(container: container)
        let service = try WordNoteV2ContentService(container: container, undoHistory: history)
        let before = try Support.snapshot(container)
        let plan = try Helper.plan(["quick", "throughput"], container: container, service: service)
        let resolution = try plan.resolve()
        XCTAssertEqual(resolution.counts.records, 1)
        XCTAssertEqual(resolution.counts.candidates, 2)
        XCTAssertEqual(resolution.counts.newTerms, 1)
        XCTAssertEqual(resolution.counts.linkedCandidates, 1)
        XCTAssertEqual(resolution.counts.supplementedTerms, 0)
        XCTAssertEqual(resolution.counts.conflicts, 0)
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertFalse(container.mainContext.hasChanges)
        XCTAssertFalse(history.canUndo)
    }

    func testNewAndExistingCandidatesCommitWithOneSaveAndOneSourceRevision() throws {
        let container = try Support.container()
        var saves = 0
        let service = try WordNoteV2ContentService(container: container, save: { saves += 1; try $0.save() })
        let plan = try Helper.plan(["quick", "throughput"], container: container, service: service)
        let expected = try plan.resolve().counts
        let result = try service.commitConfirmationPlan(plan, at: Support.now)
        let snapshot = try Support.snapshot(container)
        XCTAssertEqual(result.counts, expected)
        XCTAssertFalse(result.wasAlreadyApplied)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(snapshot.content.terms.count, 5)
        XCTAssertEqual(snapshot.occurrences.count, 2)
        let candidates = try ["quick", "throughput"].map { try Support.candidate($0, in: container) }
        XCTAssertTrue(candidates.allSatisfy { $0.revision == 1 && $0.savedTermID != nil && $0.status == .saved })
        let source = try Support.record(candidates[0].inputRecordID, in: container)
        XCTAssertEqual(source.revision, 1)
        XCTAssertEqual(source.status, .completed)
        XCTAssertTrue(snapshot.lookupEvents.isEmpty)
    }

    func testDefaultLinkPreservesEveryFormalFieldAndReviewHistory() throws {
        let container = try Support.container()
        let candidate = try Support.candidate("quick", in: container)
        candidate.chineseMeaning = "Different proposed meaning"
        candidate.englishDefinition = nil
        try container.mainContext.save()
        let target = try Support.term("quick", in: container)
        var expected = WordNoteSnapshotPayload.Term(target)
        expected.updatedAt = Support.now
        let events = try Support.snapshot(container).content.reviewEvents
        let service = try WordNoteV2ContentService(container: container)
        _ = try service.commitConfirmationPlan(Helper.plan(["quick"], container: container, service: service), at: Support.now)
        XCTAssertEqual(WordNoteSnapshotPayload.Term(target), expected)
        XCTAssertEqual(try Support.snapshot(container).content.reviewEvents, events)
    }

    func testFieldSupplementChangesOnlyExplicitNonemptyFields() throws {
        let container = try Support.container()
        let candidate = try Support.candidate("quick", in: container)
        candidate.chineseMeaning = "Selected meaning"
        candidate.englishDefinition = "Unselected definition"
        candidate.exampleSentence = "Selected example"
        try container.mainContext.save()
        let target = try Support.term("quick", in: container)
        var expected = WordNoteSnapshotPayload.Term(target)
        expected.chineseMeaning = candidate.chineseMeaning
        expected.exampleSentence = candidate.exampleSentence
        expected.updatedAt = Support.now
        let service = try WordNoteV2ContentService(container: container)
        let plan = try Helper.plan(["quick"], container: container, service: service)
        var choices = WordNoteV2ConfirmationChoices()
        choices.groups["quick", default: .init()].fieldSources = [.chineseMeaning: candidate.id, .exampleSentence: candidate.id]
        let preview = try plan.resolve(choices)
        XCTAssertEqual(preview.counts.supplementedTerms, 1)
        _ = try service.commitConfirmationPlan(plan, choices: choices, at: Support.now)
        XCTAssertEqual(WordNoteSnapshotPayload.Term(target), expected)
        XCTAssertEqual(target.revision, 1)
        _ = try Support.snapshot(container)
    }

    func testFieldsCanComeFromDifferentCandidatesWithoutConcatenation() throws {
        let container = try Support.container()
        let first = try Support.candidate("quick", in: container)
        let second = try Helper.duplicate(first, in: container)
        first.chineseMeaning = "First meaning"
        second.chineseMeaning = "Second meaning"
        second.englishDefinition = "Second definition"
        try container.mainContext.save()
        let service = try WordNoteV2ContentService(container: container)
        let plan = try service.makeConfirmationPlan(Helper.selections([first, second], in: container))
        var choices = WordNoteV2ConfirmationChoices()
        choices.groups["quick", default: .init()].fieldSources = [.chineseMeaning: first.id, .englishDefinition: second.id]
        _ = try service.commitConfirmationPlan(plan, choices: choices)
        let target = try Support.term("quick", in: container)
        XCTAssertEqual(target.chineseMeaning, "First meaning")
        XCTAssertEqual(target.englishDefinition, "Second definition")
        XCTAssertEqual(try Support.snapshot(container).occurrences.count, 1)
    }

    func testIdenticalNewCandidatesCreateOneTermAndOneOccurrenceForSameCapture() throws {
        let container = try Support.container()
        let first = try Support.candidate("throughput", in: container)
        let second = try Helper.duplicate(first, in: container)
        second.term = "  THROUGHPUT  "
        second.normalizedTerm = TextNormalizer.normalized(second.term)
        try container.mainContext.save()
        let service = try WordNoteV2ContentService(container: container)
        let plan = try service.makeConfirmationPlan(Helper.selections([first, second], in: container))
        let result = try service.commitConfirmationPlan(plan)
        XCTAssertEqual(result.counts.newTerms, 1)
        XCTAssertEqual(result.counts.linkedCandidates, 1)
        XCTAssertEqual(first.savedTermID, second.savedTermID)
        XCTAssertEqual(try Support.snapshot(container).occurrences.count, 1)
        XCTAssertEqual(try Support.snapshot(container).content.terms.count, 5)
    }

    func testSameNewWordFromTwoSourcesRetainsBothOccurrencesAndCourses() throws {
        let container = try Support.container()
        let first = try Support.candidate("throughput", in: container)
        let second = try Helper.duplicate(first, in: container, separateSource: true)
        let source = try Support.record(second.inputRecordID, in: container)
        let originalCourseID = try Support.record(first.inputRecordID, in: container).courseID
        source.courseID = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV2.CourseModel>())
            .first { $0.id != originalCourseID }).id
        try container.mainContext.save()
        let service = try WordNoteV2ContentService(container: container)
        let result = try service.commitConfirmationPlan(service.makeConfirmationPlan(Helper.selections([first, second], in: container)))
        let snapshot = try Support.snapshot(container)
        XCTAssertEqual(result.counts.records, 2)
        XCTAssertEqual(result.counts.newTerms, 1)
        XCTAssertEqual(snapshot.occurrences.filter { $0.termID == first.savedTermID }.count, 2)
        XCTAssertEqual(snapshot.courseLinks.filter { $0.termID == first.savedTermID }.count, 2)
        XCTAssertEqual(try Support.record(first.inputRecordID, in: container).revision, 1)
        XCTAssertEqual(source.revision, 1)
    }

    func testDifferentNewMeaningsRequireExplicitPrimaryCandidate() throws {
        let container = try Support.container()
        let first = try Support.candidate("throughput", in: container)
        let second = try Helper.duplicate(first, in: container)
        second.chineseMeaning = "Different sense"
        try container.mainContext.save()
        let service = try WordNoteV2ContentService(container: container)
        let plan = try service.makeConfirmationPlan(Helper.selections([first, second], in: container))
        let before = try Support.snapshot(container)
        XCTAssertEqual(try plan.resolve().counts.conflicts, 1)
        XCTAssertEqual(try plan.resolve().counts.unresolvedCandidates, 2)
        XCTAssertThrowsError(try service.commitConfirmationPlan(plan))
        XCTAssertEqual(try Support.snapshot(container), before)
        var choices = WordNoteV2ConfirmationChoices()
        choices.groups["throughput", default: .init()].preferredCandidateID = second.id
        _ = try service.commitConfirmationPlan(plan, choices: choices)
        XCTAssertEqual(try Support.term("throughput", in: container).chineseMeaning, "Different sense")
        XCTAssertEqual(first.savedTermID, second.savedTermID)
    }

    func testIgnoringConflictingCandidateResolvesGroupAndPersistsIgnore() throws {
        let container = try Support.container()
        let first = try Support.candidate("throughput", in: container)
        let second = try Helper.duplicate(first, in: container)
        second.chineseMeaning = "Not selected"
        try container.mainContext.save()
        let service = try WordNoteV2ContentService(container: container)
        let plan = try service.makeConfirmationPlan(Helper.selections([first, second], in: container))
        var choices = WordNoteV2ConfirmationChoices()
        choices.ignoredCandidateIDs = [second.id]
        let result = try service.commitConfirmationPlan(plan, choices: choices)
        XCTAssertEqual(result.counts.ignoredCandidates, 1)
        XCTAssertEqual(second.status, .ignored)
        XCTAssertNil(second.confirmationOperationID)
        XCTAssertNil(second.savedTermID)
        XCTAssertEqual(try Support.term("throughput", in: container).chineseMeaning, first.chineseMeaning)
        _ = try Support.snapshot(container)
    }

    func testAmbiguousExistingNamesRequireExplicitTarget() throws {
        let container = try Support.container()
        let extra = Term(term: "QUICK", termType: .word, chineseMeaning: "Another existing entry")
        container.mainContext.insert(extra)
        try container.mainContext.save()
        let service = try WordNoteV2ContentService(container: container)
        let plan = try Helper.plan(["quick"], container: container, service: service)
        XCTAssertEqual(try plan.resolve().conflicts.count, 1)
        var choices = WordNoteV2ConfirmationChoices()
        choices.groups["quick", default: .init()].existingTermID = extra.id
        _ = try service.commitConfirmationPlan(plan, choices: choices)
        XCTAssertEqual(try Support.candidate("quick", in: container).savedTermID, extra.id)
        XCTAssertEqual(try Support.snapshot(container).content.terms.count, 5)
    }

    func testUnknownAndCrossGroupChoicesAreRejected() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let plan = try Helper.plan(["quick", "throughput"], container: container, service: service)
        let unrelated = try Support.candidate("overfitting", in: container)
        var cases: [WordNoteV2ConfirmationChoices] = []
        var choices = WordNoteV2ConfirmationChoices()
        choices.ignoredCandidateIDs = [unrelated.id]
        cases.append(choices)
        choices = .init(); choices.groups["unknown"] = .init(); cases.append(choices)
        choices = .init(); choices.groups["quick", default: .init()].existingTermID = UUID(); cases.append(choices)
        choices = .init(); choices.groups["quick", default: .init()].fieldSources[.chineseMeaning] = unrelated.id; cases.append(choices)
        choices = .init(); choices.groups["throughput", default: .init()].preferredCandidateID = unrelated.id; cases.append(choices)
        for invalid in cases { XCTAssertThrowsError(try plan.resolve(invalid)) }
    }

    func testSupplementCannotClearStoredFieldOrReadIgnoredCandidate() throws {
        let container = try Support.container()
        let candidate = try Support.candidate("quick", in: container)
        candidate.chineseMeaning = "  "
        try container.mainContext.save()
        let service = try WordNoteV2ContentService(container: container)
        let plan = try Helper.plan(["quick"], container: container, service: service)
        var choices = WordNoteV2ConfirmationChoices()
        choices.groups["quick", default: .init()].fieldSources[.chineseMeaning] = candidate.id
        XCTAssertThrowsError(try plan.resolve(choices))
        choices.ignoredCandidateIDs = [candidate.id]
        XCTAssertThrowsError(try plan.resolve(choices))
    }

    func testChineseLookupUsesFrozenDirectionAndKeepsEnglishSubject() throws {
        let container = try Support.container()
        let candidate = try Support.candidate("overfitting", in: container)
        let term = try Support.term("overfitting", in: container)
        term.chineseMeaning = nil
        term.englishDefinition = "A model fitting training data too closely."
        try container.mainContext.save()
        let service = try WordNoteV2ContentService(container: container)
        let plan = try Helper.plan(["overfitting"], container: container, service: service)
        XCTAssertEqual(try plan.resolve().conflicts.count, 1)
        var choices = WordNoteV2ConfirmationChoices()
        choices.groups["overfitting", default: .init()].fieldSources[.chineseMeaning] = candidate.id
        _ = try service.commitConfirmationPlan(plan, choices: choices)
        XCTAssertEqual(term.term, "overfitting")
        XCTAssertEqual(term.chineseMeaning, candidate.chineseMeaning)
        XCTAssertEqual(candidate.savedTermID, term.id)
    }

    func testInvalidHeadwordOrMissingDefinitionCanOnlyBeEditedOrIgnored() throws {
        for value in ["中文主體", "throughput"] {
            let container = try Support.container()
            let candidate = try Support.candidate("throughput", in: container)
            candidate.term = value
            candidate.normalizedTerm = TextNormalizer.normalized(value)
            candidate.chineseMeaning = nil
            candidate.englishDefinition = nil
            try container.mainContext.save()
            let service = try WordNoteV2ContentService(container: container)
            let plan = try service.makeConfirmationPlan(Helper.selections([candidate], in: container))
            XCTAssertEqual(try plan.resolve().conflicts.count, 1)
            var choices = WordNoteV2ConfirmationChoices()
            choices.ignoredCandidateIDs = [candidate.id]
            XCTAssertTrue(try plan.resolve(choices).conflicts.isEmpty)
            _ = try service.commitConfirmationPlan(plan, choices: choices)
            XCTAssertEqual(candidate.status, .ignored)
        }
    }

    func testEnglishSymbolsRemainValidHeadwords() throws {
        for value in ["C++", "L2"] {
            let container = try Support.container()
            let candidate = try Support.candidate("throughput", in: container)
            candidate.term = value
            candidate.normalizedTerm = TextNormalizer.normalized(value)
            try container.mainContext.save()
            let service = try WordNoteV2ContentService(container: container)
            let plan = try service.makeConfirmationPlan(Helper.selections([candidate], in: container))
            _ = try service.commitConfirmationPlan(plan)
            XCTAssertEqual(try Support.term(value, in: container).term, value)
        }
    }

    func testIgnoringChosenCandidateClearsOnlyItsDependentChoices() throws {
        let container = try Support.container()
        let first = try Support.candidate("quick", in: container)
        let second = try Helper.duplicate(first, in: container)
        let service = try WordNoteV2ContentService(container: container)
        let plan = try service.makeConfirmationPlan(Helper.selections([first, second], in: container))
        var choices = WordNoteV2ConfirmationChoices()
        choices.groups["quick", default: .init()].fieldSources = [.chineseMeaning: first.id, .englishDefinition: second.id]
        try choices.setIgnored(true, candidateID: first.id, in: plan)
        XCTAssertNil(choices.groups["quick"]?.fieldSources[.chineseMeaning])
        XCTAssertEqual(choices.groups["quick"]?.fieldSources[.englishDefinition], second.id)
        try choices.setIgnored(true, candidateID: second.id, in: plan)
        XCTAssertEqual(choices.groups["quick"], .init())
        XCTAssertTrue(try plan.resolve(choices).conflicts.isEmpty)
        try choices.setIgnored(false, candidateID: first.id, in: plan)
        XCTAssertEqual(try plan.resolve(choices).counts.linkedCandidates, 1)
        XCTAssertThrowsError(try choices.setIgnored(true, candidateID: UUID(), in: plan))
    }

    func testIgnoringPreferredNewCandidateResetsPrimaryChoice() throws {
        let container = try Support.container()
        let first = try Support.candidate("throughput", in: container)
        let second = try Helper.duplicate(first, in: container)
        let service = try WordNoteV2ContentService(container: container)
        let plan = try service.makeConfirmationPlan(Helper.selections([first, second], in: container))
        var choices = WordNoteV2ConfirmationChoices()
        choices.groups["throughput", default: .init()].preferredCandidateID = first.id
        try choices.setIgnored(true, candidateID: first.id, in: plan)
        XCTAssertNil(choices.groups["throughput"]?.preferredCandidateID)
        XCTAssertEqual(try plan.resolve(choices).groups.first?.primaryCandidateID, second.id)
    }

    func testChangingExistingTargetClearsPreviousOverwriteChoices() throws {
        let container = try Support.container()
        let first = try Support.term("quick", in: container)
        let extra = Term(term: "QUICK", termType: .word, chineseMeaning: "Another manual meaning")
        container.mainContext.insert(extra)
        try container.mainContext.save()
        let service = try WordNoteV2ContentService(container: container)
        let plan = try Helper.plan(["quick"], container: container, service: service)
        let candidate = try Support.candidate("quick", in: container)
        var choices = WordNoteV2ConfirmationChoices()
        try choices.setExistingTarget(first.id, groupID: "quick", in: plan)
        choices.groups["quick", default: .init()].fieldSources[.chineseMeaning] = candidate.id
        try choices.setExistingTarget(first.id, groupID: "quick", in: plan)
        XCTAssertEqual(choices.groups["quick"]?.fieldSources[.chineseMeaning], candidate.id)
        try choices.setExistingTarget(extra.id, groupID: "quick", in: plan)
        XCTAssertTrue(choices.groups["quick"]?.fieldSources.isEmpty == true)
        XCTAssertEqual(try plan.resolve(choices).groups.first?.content.chineseMeaning, "Another manual meaning")
        try choices.setExistingTarget(nil, groupID: "quick", in: plan)
        XCTAssertEqual(try plan.resolve(choices).conflicts.count, 1)
    }

    func testUnknownOrFullyIgnoredTargetChoiceCannotBeApplied() throws {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        let plan = try Helper.plan(["quick", "throughput"], container: container, service: service)
        var choices = WordNoteV2ConfirmationChoices()
        XCTAssertThrowsError(try choices.setExistingTarget(UUID(), groupID: "quick", in: plan))
        XCTAssertThrowsError(try choices.setExistingTarget(nil, groupID: "throughput", in: plan))
        XCTAssertThrowsError(try choices.setExistingTarget(nil, groupID: "unknown", in: plan))
        try choices.setIgnored(true, candidateID: Support.candidate("quick", in: container).id, in: plan)
        XCTAssertThrowsError(try choices.setExistingTarget(nil, groupID: "quick", in: plan))
    }

    func testInconsistentStoredHeadwordCannotBeLinked() throws {
        let container = try Support.container()
        let target = try Support.term("quick", in: container)
        target.term = "different"
        try container.mainContext.save()
        let service = try WordNoteV2ContentService(container: container)
        let plan = try Helper.plan(["quick"], container: container, service: service)
        XCTAssertEqual(try plan.resolve().conflicts.count, 1)
        XCTAssertThrowsError(try service.commitConfirmationPlan(plan))
        XCTAssertEqual(try Support.candidate("quick", in: container).status, .pending)
    }
}

@MainActor
enum ConfirmationPlanTestSupport {
    typealias Support = WordNoteV2ServiceTestSupport
    typealias Candidate = WordNoteSchemaV2.CandidateTermModel

    static func selections(_ candidates: [Candidate], in container: ModelContainer) throws -> [WordNoteV2CandidateSelection] {
        try candidates.map { candidate in
            .init(id: candidate.id, revision: candidate.revision, recordID: candidate.inputRecordID,
                  recordRevision: try Support.record(candidate.inputRecordID, in: container).revision)
        }
    }

    static func plan(_ names: [String], container: ModelContainer, service: WordNoteV2ContentService) throws -> WordNoteV2ConfirmationPlan {
        try service.makeConfirmationPlan(selections(names.map { try Support.candidate($0, in: container) }, in: container))
    }

    static func duplicate(_ candidate: Candidate, in container: ModelContainer, separateSource: Bool = false) throws -> Candidate {
        var content = WordNoteSnapshotPayload.Candidate(candidate)
        content.id = UUID()
        if separateSource {
            let original = try Support.record(candidate.inputRecordID, in: container)
            var source = WordNoteSnapshotPayload.InputRecord(original)
            source.id = UUID()
            let model = try source.modelV2()
            model.analysisGeneration = original.analysisGeneration
            container.mainContext.insert(model)
            content.inputRecordID = model.id
        }
        let duplicate = try content.modelV2()
        duplicate.analysisGeneration = candidate.analysisGeneration
        container.mainContext.insert(duplicate)
        try container.mainContext.save()
        return duplicate
    }
}
