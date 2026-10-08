import SwiftData

extension WordNoteSnapshotPayload.Course {
    public init(_ model: WordNoteSchemaV3.CourseModel) {
        id = model.id
        courseName = model.courseName
        courseCode = model.courseCode
        instructor = model.instructor
        semester = model.semester
        courseDescription = model.courseDescription
        createdAt = model.createdAt
        updatedAt = model.updatedAt
    }

    func modelV3() -> WordNoteSchemaV3.CourseModel {
        WordNoteSchemaV3.CourseModel(
            id: id, courseName: courseName, courseCode: courseCode, instructor: instructor,
            semester: semester, courseDescription: courseDescription, createdAt: createdAt, updatedAt: updatedAt
        )
    }
}

extension WordNoteSnapshotPayload.InputRecord {
    init(_ model: WordNoteSchemaV3.InputRecordModel) {
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

    func modelV3() throws -> WordNoteSchemaV3.InputRecordModel {
        let model = WordNoteSchemaV3.InputRecordModel(
            id: id, rawText: rawText, inputType: try snapshotEnum(inputTypeRaw),
            status: try snapshotEnum(statusRaw), sentenceMeaning: sentenceMeaning,
            courseID: courseID, sourceType: try snapshotEnum(sourceTypeRaw), note: note,
            aiErrorSummary: aiErrorSummary, analyzedAt: analyzedAt, createdAt: createdAt, updatedAt: updatedAt
        )
        model.normalizedText = normalizedText
        return model
    }
}

extension WordNoteSnapshotPayload.Candidate {
    public init(_ model: WordNoteSchemaV3.CandidateTermModel) {
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

    func modelV3() throws -> WordNoteSchemaV3.CandidateTermModel {
        let model = WordNoteSchemaV3.CandidateTermModel(
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

extension WordNoteSnapshotPayload.Term {
    public init(_ model: WordNoteSchemaV3.TermModel) {
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

    func modelV3() throws -> WordNoteSchemaV3.TermModel {
        let model = WordNoteSchemaV3.TermModel(
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

extension WordNoteSnapshotPayload.ReviewEvent {
    init(_ model: WordNoteSchemaV3.ReviewEventModel) {
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

    func modelV3() throws -> WordNoteSchemaV3.ReviewEventModel {
        WordNoteSchemaV3.ReviewEventModel(
            id: id, termID: termID, mode: try snapshotEnum(modeRaw), feedback: try snapshotEnum(feedbackRaw),
            previousMasteryLevel: try snapshotEnum(previousMasteryLevelRaw),
            newMasteryLevel: try snapshotEnum(newMasteryLevelRaw),
            previousNextReviewAt: previousNextReviewAt, newNextReviewAt: newNextReviewAt, reviewedAt: reviewedAt
        )
    }
}
