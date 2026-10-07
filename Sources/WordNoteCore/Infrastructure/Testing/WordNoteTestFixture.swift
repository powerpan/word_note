import Foundation
import SwiftData

public enum WordNoteTestFixture: String, Sendable {
    case empty
    case populated

    public static let referenceDate = Date(timeIntervalSince1970: 1_790_000_000)

    @MainActor
    public func populate(_ context: ModelContext) throws {
        let counts = [
            try context.fetchCount(FetchDescriptor<CourseModel>()),
            try context.fetchCount(FetchDescriptor<InputRecordModel>()),
            try context.fetchCount(FetchDescriptor<CandidateTermModel>()),
            try context.fetchCount(FetchDescriptor<TermModel>()),
            try context.fetchCount(FetchDescriptor<ReviewEventModel>())
        ]
        guard counts.allSatisfy({ $0 == 0 }) else { throw FixtureError.nonEmptyStore }
        guard self == .populated else { return }

        let date = Self.referenceDate
        let course = CourseModel(
            id: Self.id(1), courseName: "Computer Science", courseCode: "CS-50",
            createdAt: date, updatedAt: date
        )
        let secondCourse = CourseModel(
            id: Self.id(2), courseName: "Machine Learning and Statistical Pattern Recognition",
            courseCode: "ML-101", createdAt: date, updatedAt: date
        )
        context.insert(course)
        context.insert(secondCourse)

        let examples: [(String, String)] = [
            ("quick", "迅速的；敏捷的；短時間完成的"),
            ("overfitting", "過擬合：模型過度貼合訓練資料，對新資料的泛化能力下降。"),
            ("gradient descent", "梯度下降：沿目標函數梯度的反方向逐步更新參數。"),
            ("out-of-distribution generalization", "分布外泛化：將已學到的規律應用到與訓練分布不同的新資料。")
        ]
        for (index, example) in examples.enumerated() {
            let term = TermModel(
                id: Self.id(10 + index), term: example.0,
                termType: example.0.contains(" ") ? .phrase : .word,
                chineseMeaning: example.1,
                englishDefinition: index == 0 ? "Moving or happening with little delay." : nil,
                exampleSentence: index == 0 ? "She gave a quick response." : nil,
                courseID: index < 2 ? course.id : secondCourse.id,
                sourceType: .class, tags: ["fixture"],
                importance: index == 1 ? .high : .medium,
                masteryLevel: index == 0 ? .familiar : .new,
                reviewIntervalDays: index == 0 ? 3 : 0,
                correctStreak: index == 0 ? 1 : 0,
                reviewCount: index == 0 ? 1 : 0,
                lastReviewedAt: index == 0 ? date : nil,
                nextReviewAt: date, createdAt: date, updatedAt: date
            )
            context.insert(term)
        }

        let chineseRecord = InputRecordModel(
            id: Self.id(20), rawText: "過擬合", inputType: .word, status: .analyzed,
            courseID: course.id, sourceType: .class, analyzedAt: date,
            createdAt: date, updatedAt: date
        )
        let duplicateRecord = InputRecordModel(
            id: Self.id(21), rawText: "A quick response improves throughput.",
            inputType: .sentence, status: .analyzed,
            sentenceMeaning: "快速回應有助於提高吞吐量。", courseID: course.id,
            sourceType: .book, analyzedAt: date, createdAt: date, updatedAt: date
        )
        let failedRecord = InputRecordModel(
            id: Self.id(22), rawText: "bounded queue", status: .failed,
            sourceType: .paper, aiErrorSummary: "Offline fixture: simulated timeout.",
            createdAt: date, updatedAt: date
        )
        [chineseRecord, duplicateRecord, failedRecord].forEach(context.insert)
        let candidates = [
            CandidateTermModel(
                id: Self.id(30), inputRecordID: chineseRecord.id, term: "overfitting",
                termType: .word, needToLearn: true, importance: .high, category: .aiML,
                chineseMeaning: examples[1].1, confidence: 0.95, createdAt: date, updatedAt: date
            ),
            CandidateTermModel(
                id: Self.id(31), inputRecordID: duplicateRecord.id, term: "quick",
                termType: .word, needToLearn: true, importance: .medium, category: .general,
                chineseMeaning: examples[0].1, confidence: 0.9, createdAt: date, updatedAt: date
            ),
            CandidateTermModel(
                id: Self.id(32), inputRecordID: duplicateRecord.id, term: "throughput",
                termType: .word, needToLearn: true, importance: .high, category: .programming,
                chineseMeaning: "吞吐量：單位時間內完成處理的工作量。", confidence: 0.9,
                createdAt: date, updatedAt: date
            )
        ]
        candidates.forEach(context.insert)
        context.insert(ReviewEventModel(
            id: Self.id(40), termID: Self.id(10), mode: .englishToChinese, feedback: .good,
            previousMasteryLevel: .new, newMasteryLevel: .familiar,
            previousNextReviewAt: date.addingTimeInterval(-86_400),
            newNextReviewAt: date, reviewedAt: date
        ))
        try context.save()
    }

    public static func analysisResult(for request: AIAnalysisRequest) -> AIAnalysisResult {
        let chineseLookup = request.lookupDirection == .chineseToEnglish
        return AIAnalysisResult(
            inputType: .word, sentenceMeaning: nil,
            candidates: [AIAnalysisCandidate(
                term: chineseLookup ? "overfitting" : request.rawText,
                termType: .word, needToLearn: true, importance: .high, category: .aiML,
                chineseMeaning: "過擬合：模型過度貼合訓練資料，對新資料的泛化能力下降。",
                confidence: 0.95
            )],
            model: "offline-ui-fixture", rawResponseID: nil
        )
    }

    private static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
    }

    public enum FixtureError: Error {
        case nonEmptyStore
    }
}
