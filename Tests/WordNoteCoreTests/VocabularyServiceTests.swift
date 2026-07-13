import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class VocabularyServiceTests: XCTestCase {
    func testCreateTermsFromCandidatesPersistsTermsAndMarksRecordCompleted() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let inputService = InputRecordService(modelContext: context)
        let vocabularyService = VocabularyService(modelContext: context)
        let record = try inputService.createAnalyzing(
            rawText: "The model learns a latent representation.",
            courseID: nil,
            sourceType: .paper,
            note: nil
        )
        let result = AIAnalysisResult(
            inputType: .sentence,
            sentenceMeaning: "模型學習一種隱含表示。",
            candidates: [
                AIAnalysisCandidate(
                    term: "latent representation",
                    termType: .phrase,
                    needToLearn: true,
                    importance: .high,
                    category: .aiML,
                    chineseMeaning: "隱含表示",
                    englishDefinition: "An internal representation learned by a model."
                )
            ],
            model: "test",
            rawResponseID: nil
        )
        let candidates = try inputService.applyAnalysisResult(result, to: record)

        let terms = try vocabularyService.createTerms(from: candidates, sourceRecord: record)

        XCTAssertEqual(terms.count, 1)
        XCTAssertEqual(terms.first?.term, "latent representation")
        XCTAssertEqual(terms.first?.contextSentence, record.rawText)
        XCTAssertEqual(terms.first?.sourceRecordID, record.id)
        XCTAssertEqual(terms.first?.nextReviewAt == nil, false)
        XCTAssertEqual(candidates.first?.status, .saved)
        XCTAssertEqual(record.status, .completed)

        let persistedTerms = try context.fetch(FetchDescriptor<TermModel>())
        XCTAssertEqual(persistedTerms.map(\.normalizedTerm), ["latent representation"])
    }

    func testDuplicateTermIsRejected() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let inputService = InputRecordService(modelContext: context)
        let vocabularyService = VocabularyService(modelContext: context)
        let existing = TermModel(
            term: "gradient descent",
            termType: .phrase,
            chineseMeaning: "梯度下降"
        )
        context.insert(existing)
        let record = try inputService.createDraft(
            rawText: "gradient descent",
            courseID: nil,
            sourceType: .class,
            note: nil
        )
        let candidate = CandidateTermModel(
            inputRecordID: record.id,
            term: "Gradient Descent",
            termType: .phrase,
            needToLearn: true,
            importance: .high,
            category: .aiML,
            chineseMeaning: "梯度下降"
        )
        context.insert(candidate)
        try context.save()

        XCTAssertThrowsError(
            try vocabularyService.createTerms(from: [candidate], sourceRecord: record)
        ) { error in
            guard case VocabularyServiceError.duplicateTerm = error else {
                return XCTFail("Expected duplicate error, got \(error)")
            }
        }
    }

    func testFindExactTermMatchesOnlyWholeNormalizedInput() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let vocabularyService = VocabularyService(modelContext: context)
        let term = TermModel(
            term: "regularization",
            termType: .word,
            chineseMeaning: "正則化"
        )
        context.insert(term)
        try context.save()

        let exactMatch = try vocabularyService.findExactTerm(rawText: "  Regularization  ")
        let containingSentence = try vocabularyService.findExactTerm(rawText: "Use regularization to reduce overfitting.")

        XCTAssertEqual(exactMatch?.id, term.id)
        XCTAssertNil(containingSentence)
    }

    func testBumpDuplicateHitPromotesReviewPriorityWithoutCreatingInboxArtifacts() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let vocabularyService = VocabularyService(modelContext: context)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let term = TermModel(
            term: "regularization",
            termType: .word,
            chineseMeaning: "正則化",
            importance: .low,
            masteryLevel: .mastered,
            reviewIntervalDays: 14,
            correctStreak: 3,
            wrongCount: 0,
            nextReviewAt: now.addingTimeInterval(7 * 24 * 60 * 60)
        )
        context.insert(term)
        try context.save()

        try vocabularyService.bumpDuplicateHit(term, at: now)

        XCTAssertEqual(term.nextReviewAt, now)
        XCTAssertEqual(term.importance, .medium)
        XCTAssertEqual(term.masteryLevel, .vague)
        XCTAssertEqual(term.correctStreak, 0)
        XCTAssertEqual(term.duplicateHitCount, 1)
        XCTAssertEqual(term.lastDuplicateHitAt, now)
        XCTAssertEqual(term.wrongCount, 1)

        let records = try context.fetch(FetchDescriptor<InputRecordModel>())
        let candidates = try context.fetch(FetchDescriptor<CandidateTermModel>())
        let reviewEvents = try context.fetch(FetchDescriptor<ReviewEventModel>())
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertTrue(reviewEvents.isEmpty)
    }

    func testBumpDuplicateHitUsesWrongCountCooldownButAlwaysCountsDuplicateHit() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let vocabularyService = VocabularyService(modelContext: context)
        let firstHitAt = Date(timeIntervalSince1970: 1_700_000_000)
        let term = TermModel(
            term: "gradient descent",
            termType: .phrase,
            chineseMeaning: "梯度下降",
            importance: .medium,
            masteryLevel: .vague,
            wrongCount: 4,
            duplicateHitCount: 2
        )
        context.insert(term)
        try context.save()

        try vocabularyService.bumpDuplicateHit(term, at: firstHitAt, wrongCountCooldown: 600)
        try vocabularyService.bumpDuplicateHit(
            term,
            at: firstHitAt.addingTimeInterval(300),
            wrongCountCooldown: 600
        )
        try vocabularyService.bumpDuplicateHit(
            term,
            at: firstHitAt.addingTimeInterval(901),
            wrongCountCooldown: 600
        )

        XCTAssertEqual(term.masteryLevel, .vague)
        XCTAssertEqual(term.importance, .high)
        XCTAssertEqual(term.duplicateHitCount, 5)
        XCTAssertEqual(term.wrongCount, 6)
    }

    func testUpdateAndDeleteTermPersist() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let vocabularyService = VocabularyService(modelContext: context)
        let term = TermModel(
            term: "regularization",
            termType: .word,
            chineseMeaning: "正則化"
        )
        context.insert(term)
        try context.save()

        try vocabularyService.updateTerm(
            term,
            termText: "L2 regularization",
            termType: .phrase,
            chineseMeaning: "L2 正則化",
            englishDefinition: "A penalty on large weights.",
            aiContextExplanation: "Used to reduce overfitting.",
            exampleSentence: "L2 regularization penalizes large weights.",
            contextSentence: "We add L2 regularization to the loss.",
            courseID: nil,
            sourceType: .slides,
            category: .aiML,
            importance: .high,
            masteryLevel: .familiar
        )

        XCTAssertEqual(term.normalizedTerm, "l2 regularization")
        XCTAssertEqual(term.termType, .phrase)
        XCTAssertEqual(term.masteryLevel, .familiar)

        try vocabularyService.delete(term)
        let terms = try context.fetch(FetchDescriptor<TermModel>())
        XCTAssertTrue(terms.isEmpty)
    }

    func testCreateTermsRejectsDuplicatesWithinSameSelection() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let inputService = InputRecordService(modelContext: context)
        let service = VocabularyService(modelContext: context)
        let record = try inputService.createDraft(
            rawText: "regularization",
            courseID: nil,
            sourceType: .paper,
            note: nil
        )
        let first = CandidateTermModel(
            inputRecordID: record.id,
            term: "Regularization",
            termType: .word,
            needToLearn: true,
            importance: .high,
            category: .aiML,
            chineseMeaning: "正則化"
        )
        let second = CandidateTermModel(
            inputRecordID: record.id,
            term: " regularization ",
            termType: .word,
            needToLearn: true,
            importance: .medium,
            category: .general,
            chineseMeaning: "正規化處理"
        )
        context.insert(first)
        context.insert(second)
        try context.save()

        XCTAssertThrowsError(try service.createTerms(from: [first, second], sourceRecord: record))
        XCTAssertTrue(try context.fetch(FetchDescriptor<TermModel>()).isEmpty)
        XCTAssertEqual(first.status, .pending)
        XCTAssertEqual(second.status, .pending)
    }

    func testBatchConfirmationValidatesAllRecordsBeforeMutating() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let inputService = InputRecordService(modelContext: context)
        let service = VocabularyService(modelContext: context)
        let firstRecord = try inputService.createDraft(
            rawText: "unique term",
            courseID: nil,
            sourceType: .paper,
            note: nil
        )
        let secondRecord = try inputService.createDraft(
            rawText: "existing term",
            courseID: nil,
            sourceType: .paper,
            note: nil
        )
        let uniqueCandidate = CandidateTermModel(
            inputRecordID: firstRecord.id,
            term: "unique term",
            termType: .phrase,
            needToLearn: true,
            importance: .medium,
            category: .general,
            chineseMeaning: "唯一詞條"
        )
        let duplicateCandidate = CandidateTermModel(
            inputRecordID: secondRecord.id,
            term: "existing term",
            termType: .phrase,
            needToLearn: true,
            importance: .medium,
            category: .general,
            chineseMeaning: "既有詞條"
        )
        let existing = TermModel(
            term: "existing term",
            termType: .phrase,
            chineseMeaning: "既有詞條"
        )
        context.insert(uniqueCandidate)
        context.insert(duplicateCandidate)
        context.insert(existing)
        try context.save()

        XCTAssertThrowsError(
            try service.confirmCandidates([
                CandidateConfirmation(candidates: [uniqueCandidate], sourceRecord: firstRecord),
                CandidateConfirmation(candidates: [duplicateCandidate], sourceRecord: secondRecord)
            ])
        )

        XCTAssertEqual(try context.fetch(FetchDescriptor<TermModel>()).count, 1)
        XCTAssertEqual(uniqueCandidate.status, .pending)
        XCTAssertEqual(duplicateCandidate.status, .pending)
    }

    func testUpdateTermRejectsAnotherTermsNormalizedValue() throws {
        let context = ModelContext(try makeInMemoryContainer())
        let service = VocabularyService(modelContext: context)
        let first = TermModel(term: "regularization", termType: .word, chineseMeaning: "正則化")
        let second = TermModel(term: "gradient descent", termType: .phrase, chineseMeaning: "梯度下降")
        context.insert(first)
        context.insert(second)
        try context.save()

        XCTAssertThrowsError(
            try service.updateTerm(
                second,
                termText: " Regularization ",
                termType: .word,
                chineseMeaning: "正則化",
                englishDefinition: nil,
                aiContextExplanation: nil,
                exampleSentence: nil,
                contextSentence: nil,
                courseID: nil,
                sourceType: .other,
                category: .general,
                importance: .medium,
                masteryLevel: .new
            )
        )
        XCTAssertEqual(second.normalizedTerm, "gradient descent")
    }

    func testDeleteTermCascadesReviewEvents() throws {
        let context = ModelContext(try makeInMemoryContainer())
        let service = VocabularyService(modelContext: context)
        let term = TermModel(term: "regularization", termType: .word, chineseMeaning: "正則化")
        let event = ReviewEventModel(
            termID: term.id,
            mode: .englishToChinese,
            feedback: .good,
            previousMasteryLevel: .new,
            newMasteryLevel: .familiar
        )
        context.insert(term)
        context.insert(event)
        try context.save()

        try service.delete(term)

        XCTAssertTrue(try context.fetch(FetchDescriptor<TermModel>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ReviewEventModel>()).isEmpty)
    }

    func testCreateManualTermCompletesRecordWithoutPendingCandidates() throws {
        let context = ModelContext(try makeInMemoryContainer())
        let inputService = InputRecordService(modelContext: context)
        let service = VocabularyService(modelContext: context)
        let record = try inputService.createDraft(
            rawText: "ablation study",
            courseID: nil,
            sourceType: .paper,
            note: nil
        )

        let term = try service.createManualTerm(
            termText: "ablation study",
            chineseMeaning: "消融研究",
            englishDefinition: nil,
            sourceRecord: record
        )

        XCTAssertEqual(term.termType, .phrase)
        XCTAssertEqual(record.status, .completed)
    }

    func testChineseLookupSavesEnglishVocabularySubjectWithChineseMeaning() throws {
        let context = ModelContext(try makeInMemoryContainer())
        let inputService = InputRecordService(modelContext: context)
        let service = VocabularyService(modelContext: context)
        let record = try inputService.createDraft(
            rawText: "過擬合",
            courseID: nil,
            sourceType: .class,
            note: nil
        )
        let candidate = CandidateTermModel(
            inputRecordID: record.id,
            term: "overfitting",
            termType: .word,
            needToLearn: true,
            importance: .high,
            category: .aiML,
            chineseMeaning: "過擬合；模型過度貼合訓練資料。"
        )
        context.insert(candidate)
        try context.save()

        let term = try service.createTerms(from: [candidate], sourceRecord: record).first

        XCTAssertEqual(term?.term, "overfitting")
        XCTAssertEqual(term?.chineseMeaning, "過擬合；模型過度貼合訓練資料。")
        XCTAssertEqual(term?.contextSentence, "過擬合")
    }

    func testChineseLookupRejectsChineseVocabularySubjectAtConfirmation() throws {
        let context = ModelContext(try makeInMemoryContainer())
        let inputService = InputRecordService(modelContext: context)
        let service = VocabularyService(modelContext: context)
        let record = try inputService.createDraft(
            rawText: "過擬合",
            courseID: nil,
            sourceType: .class,
            note: nil
        )
        let candidate = CandidateTermModel(
            inputRecordID: record.id,
            term: "過擬合",
            termType: .word,
            needToLearn: true,
            importance: .high,
            category: .aiML,
            chineseMeaning: "過擬合"
        )
        context.insert(candidate)
        try context.save()

        XCTAssertThrowsError(
            try service.createTerms(from: [candidate], sourceRecord: record)
        ) { error in
            guard case VocabularyServiceError.englishTermRequired = error else {
                return XCTFail("Expected English-term validation, got \(error).")
            }
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<TermModel>()).isEmpty)
        XCTAssertEqual(candidate.status, .pending)
    }

    func testChineseLookupRequiresChineseMeaningAtConfirmation() throws {
        let context = ModelContext(try makeInMemoryContainer())
        let inputService = InputRecordService(modelContext: context)
        let service = VocabularyService(modelContext: context)
        let record = try inputService.createDraft(
            rawText: "過擬合",
            courseID: nil,
            sourceType: .class,
            note: nil
        )
        let candidate = CandidateTermModel(
            inputRecordID: record.id,
            term: "overfitting",
            termType: .word,
            needToLearn: true,
            importance: .high,
            category: .aiML,
            englishDefinition: "Fitting training data too closely."
        )
        context.insert(candidate)
        try context.save()

        XCTAssertThrowsError(
            try service.createTerms(from: [candidate], sourceRecord: record)
        ) { error in
            guard case VocabularyServiceError.chineseMeaningRequired = error else {
                return XCTFail("Expected Chinese-meaning validation, got \(error).")
            }
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<TermModel>()).isEmpty)
        XCTAssertEqual(candidate.status, .pending)
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            CourseModel.self,
            InputRecordModel.self,
            CandidateTermModel.self,
            TermModel.self,
            ReviewEventModel.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
