import Foundation
import SwiftData

public struct WordNoteSnapshotPayload: Codable, Equatable, Sendable {
    public var courses: [Course]
    public var inputRecords: [InputRecord]
    public var candidates: [Candidate]
    public var terms: [Term]
    public var reviewEvents: [ReviewEvent]
    public var preferences: Preferences

    public var canonicalized: Self {
        var result = self
        result.courses.sort { $0.id.uuidString < $1.id.uuidString }
        result.inputRecords.sort { $0.id.uuidString < $1.id.uuidString }
        result.candidates.sort { $0.id.uuidString < $1.id.uuidString }
        result.terms.sort { $0.id.uuidString < $1.id.uuidString }
        result.reviewEvents.sort { $0.id.uuidString < $1.id.uuidString }
        return result
    }

    public struct Preferences: Codable, Equatable, Sendable {
        public var appearance: String
        public var defaultSource: String

        public init(appearance: String = "system", defaultSource: String = "other") {
            self.appearance = appearance
            self.defaultSource = defaultSource
        }
    }

    @MainActor
    public static func capture(
        from context: ModelContext, preferences: Preferences = Preferences()
    ) throws -> Self {
        let payload = Self(
            courses: try context.fetch(FetchDescriptor<CourseModel>()).map(Course.init).sorted { $0.id.uuidString < $1.id.uuidString },
            inputRecords: try context.fetch(FetchDescriptor<InputRecordModel>()).map(InputRecord.init).sorted { $0.id.uuidString < $1.id.uuidString },
            candidates: try context.fetch(FetchDescriptor<CandidateTermModel>()).map(Candidate.init).sorted { $0.id.uuidString < $1.id.uuidString },
            terms: try context.fetch(FetchDescriptor<TermModel>()).map(Term.init).sorted { $0.id.uuidString < $1.id.uuidString },
            reviewEvents: try context.fetch(FetchDescriptor<ReviewEventModel>()).map(ReviewEvent.init).sorted { $0.id.uuidString < $1.id.uuidString },
            preferences: preferences
        )
        try payload.validate()
        return payload
    }

    // Restore only into an isolated empty context, never overwrite an open live store.
    @MainActor
    public func populateEmptyStore(_ context: ModelContext) throws {
        try validate()
        let existingCount = try context.fetchCount(FetchDescriptor<CourseModel>())
            + context.fetchCount(FetchDescriptor<InputRecordModel>())
            + context.fetchCount(FetchDescriptor<CandidateTermModel>())
            + context.fetchCount(FetchDescriptor<TermModel>())
            + context.fetchCount(FetchDescriptor<ReviewEventModel>())
        guard existingCount == 0, !context.hasChanges else { throw WordNoteSnapshotError.destinationNotEmpty }
        do {
            courses.forEach { context.insert($0.model()) }
            try inputRecords.forEach { context.insert(try $0.model()) }
            try candidates.forEach { context.insert(try $0.model()) }
            try terms.forEach { context.insert(try $0.model()) }
            try reviewEvents.forEach { context.insert(try $0.model()) }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    public struct Course: Codable, Equatable, Sendable {
        public var id: UUID
        public var courseName: String
        public var courseCode: String?
        public var instructor: String?
        public var semester: String?
        public var courseDescription: String?
        public var createdAt: Date
        public var updatedAt: Date

        @MainActor init(_ model: CourseModel) {
            id = model.id
            courseName = model.courseName
            courseCode = model.courseCode
            instructor = model.instructor
            semester = model.semester
            courseDescription = model.courseDescription
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        @MainActor func model() -> CourseModel {
            CourseModel(
                id: id, courseName: courseName, courseCode: courseCode, instructor: instructor,
                semester: semester, courseDescription: courseDescription, createdAt: createdAt, updatedAt: updatedAt
            )
        }
    }

    public struct InputRecord: Codable, Equatable, Sendable {
        public var id: UUID
        public var rawText: String
        public var normalizedText: String
        public var inputTypeRaw: String
        public var statusRaw: String
        public var sentenceMeaning: String?
        public var courseID: UUID?
        public var sourceTypeRaw: String
        public var note: String?
        public var aiErrorSummary: String?
        public var analyzedAt: Date?
        public var createdAt: Date
        public var updatedAt: Date

        @MainActor init(_ model: InputRecordModel) {
            id = model.id
            rawText = model.rawText
            normalizedText = model.normalizedText
            inputTypeRaw = model.inputTypeRaw
            statusRaw = model.statusRaw
            sentenceMeaning = model.sentenceMeaning
            courseID = model.courseID
            sourceTypeRaw = model.sourceTypeRaw
            note = model.note
            aiErrorSummary = model.aiErrorSummary
            analyzedAt = model.analyzedAt
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        @MainActor func model() throws -> InputRecordModel {
            let model = InputRecordModel(
                id: id, rawText: rawText, inputType: try snapshotEnum(inputTypeRaw),
                status: try snapshotEnum(statusRaw), sentenceMeaning: sentenceMeaning,
                courseID: courseID, sourceType: try snapshotEnum(sourceTypeRaw), note: note,
                aiErrorSummary: aiErrorSummary, analyzedAt: analyzedAt, createdAt: createdAt, updatedAt: updatedAt
            )
            model.normalizedText = normalizedText
            return model
        }
    }

    public struct Candidate: Codable, Equatable, Sendable {
        public var id: UUID
        public var inputRecordID: UUID
        public var term: String
        public var normalizedTerm: String
        public var termTypeRaw: String
        public var needToLearn: Bool
        public var importanceRaw: String
        public var categoryRaw: String
        public var reason: String?
        public var chineseMeaning: String?
        public var englishDefinition: String?
        public var aiContextExplanation: String?
        public var exampleSentence: String?
        public var relatedTerms: [String]
        public var confidence: Double
        public var statusRaw: String
        public var createdAt: Date
        public var updatedAt: Date

        @MainActor init(_ model: CandidateTermModel) {
            id = model.id
            inputRecordID = model.inputRecordID
            term = model.term
            normalizedTerm = model.normalizedTerm
            termTypeRaw = model.termTypeRaw
            needToLearn = model.needToLearn
            importanceRaw = model.importanceRaw
            categoryRaw = model.categoryRaw
            reason = model.reason
            chineseMeaning = model.chineseMeaning
            englishDefinition = model.englishDefinition
            aiContextExplanation = model.aiContextExplanation
            exampleSentence = model.exampleSentence
            relatedTerms = model.relatedTerms
            confidence = model.confidence
            statusRaw = model.statusRaw
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        @MainActor func model() throws -> CandidateTermModel {
            let model = CandidateTermModel(
                id: id, inputRecordID: inputRecordID, term: term, termType: try snapshotEnum(termTypeRaw),
                needToLearn: needToLearn, importance: try snapshotEnum(importanceRaw), category: try snapshotEnum(categoryRaw),
                reason: reason, chineseMeaning: chineseMeaning, englishDefinition: englishDefinition,
                aiContextExplanation: aiContextExplanation, exampleSentence: exampleSentence,
                relatedTerms: relatedTerms, confidence: confidence, status: try snapshotEnum(statusRaw),
                createdAt: createdAt, updatedAt: updatedAt
            )
            model.normalizedTerm = normalizedTerm
            return model
        }
    }

    public struct Term: Codable, Equatable, Sendable {
        public var id: UUID
        public var term: String
        public var normalizedTerm: String
        public var termTypeRaw: String
        public var chineseMeaning: String?
        public var englishDefinition: String?
        public var aiContextExplanation: String?
        public var exampleSentence: String?
        public var contextSentence: String?
        public var courseID: UUID?
        public var sourceRecordID: UUID?
        public var sourceTypeRaw: String
        public var tags: [String]
        public var categoryRaw: String
        public var importanceRaw: String
        public var masteryLevelRaw: String
        public var reviewIntervalDays: Int
        public var correctStreak: Int
        public var reviewCount: Int
        public var wrongCount: Int
        public var duplicateHitCount: Int
        public var lastDuplicateHitAt: Date?
        public var lastReviewedAt: Date?
        public var nextReviewAt: Date?
        public var createdAt: Date
        public var updatedAt: Date

        @MainActor init(_ model: TermModel) {
            id = model.id
            term = model.term
            normalizedTerm = model.normalizedTerm
            termTypeRaw = model.termTypeRaw
            chineseMeaning = model.chineseMeaning
            englishDefinition = model.englishDefinition
            aiContextExplanation = model.aiContextExplanation
            exampleSentence = model.exampleSentence
            contextSentence = model.contextSentence
            courseID = model.courseID
            sourceRecordID = model.sourceRecordID
            sourceTypeRaw = model.sourceTypeRaw
            tags = model.tags
            categoryRaw = model.categoryRaw
            importanceRaw = model.importanceRaw
            masteryLevelRaw = model.masteryLevelRaw
            reviewIntervalDays = model.reviewIntervalDays
            correctStreak = model.correctStreak
            reviewCount = model.reviewCount
            wrongCount = model.wrongCount
            duplicateHitCount = model.duplicateHitCount
            lastDuplicateHitAt = model.lastDuplicateHitAt
            lastReviewedAt = model.lastReviewedAt
            nextReviewAt = model.nextReviewAt
            createdAt = model.createdAt
            updatedAt = model.updatedAt
        }

        @MainActor func model() throws -> TermModel {
            let model = TermModel(
                id: id, term: term, termType: try snapshotEnum(termTypeRaw),
                chineseMeaning: chineseMeaning, englishDefinition: englishDefinition,
                aiContextExplanation: aiContextExplanation, exampleSentence: exampleSentence,
                contextSentence: contextSentence, courseID: courseID, sourceRecordID: sourceRecordID,
                sourceType: try snapshotEnum(sourceTypeRaw), tags: tags, category: try snapshotEnum(categoryRaw),
                importance: try snapshotEnum(importanceRaw), masteryLevel: try snapshotEnum(masteryLevelRaw),
                reviewIntervalDays: reviewIntervalDays, correctStreak: correctStreak, reviewCount: reviewCount,
                wrongCount: wrongCount, duplicateHitCount: duplicateHitCount,
                lastDuplicateHitAt: lastDuplicateHitAt, lastReviewedAt: lastReviewedAt, nextReviewAt: nextReviewAt,
                createdAt: createdAt, updatedAt: updatedAt
            )
            model.normalizedTerm = normalizedTerm
            return model
        }
    }

    public struct ReviewEvent: Codable, Equatable, Sendable {
        public var id: UUID
        public var termID: UUID
        public var modeRaw: String
        public var feedbackRaw: String
        public var previousMasteryLevelRaw: String
        public var newMasteryLevelRaw: String
        public var previousNextReviewAt: Date?
        public var newNextReviewAt: Date?
        public var reviewedAt: Date

        @MainActor init(_ model: ReviewEventModel) {
            id = model.id
            termID = model.termID
            modeRaw = model.modeRaw
            feedbackRaw = model.feedbackRaw
            previousMasteryLevelRaw = model.previousMasteryLevelRaw
            newMasteryLevelRaw = model.newMasteryLevelRaw
            previousNextReviewAt = model.previousNextReviewAt
            newNextReviewAt = model.newNextReviewAt
            reviewedAt = model.reviewedAt
        }

        @MainActor func model() throws -> ReviewEventModel {
            ReviewEventModel(
                id: id, termID: termID, mode: try snapshotEnum(modeRaw), feedback: try snapshotEnum(feedbackRaw),
                previousMasteryLevel: try snapshotEnum(previousMasteryLevelRaw),
                newMasteryLevel: try snapshotEnum(newMasteryLevelRaw),
                previousNextReviewAt: previousNextReviewAt, newNextReviewAt: newNextReviewAt, reviewedAt: reviewedAt
            )
        }
    }
}

private func snapshotEnum<T: RawRepresentable>(_ rawValue: String) throws -> T where T.RawValue == String {
    guard let value = T(rawValue: rawValue) else { throw WordNoteSnapshotError.invalidEnum }
    return value
}
