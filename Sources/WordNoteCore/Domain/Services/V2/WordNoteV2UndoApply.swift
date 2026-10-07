import Foundation

extension WordNoteV2ContentService {
    func applyUndo(_ receipt: WordNoteV2UndoReceipt, at date: Date) throws {
        let before = receipt.before.values
        let scope = receipt.scope
        let oldTermIDs = Set(before.content.terms.map(\.id))
        let oldCourseIDs = Set(before.content.courses.map(\.id))

        for value in before.content.courses {
            let model = try course(value.id)
            model.courseName = value.courseName
            model.courseCode = value.courseCode
            model.instructor = value.instructor
            model.semester = value.semester
            model.courseDescription = value.courseDescription
            model.revision = try increment(model.revision)
            model.updatedAt = date
        }
        for value in before.content.terms {
            let model = try term(value.id)
            model.term = value.term
            model.normalizedTerm = value.normalizedTerm
            model.termTypeRaw = value.termTypeRaw
            model.chineseMeaning = value.chineseMeaning
            model.englishDefinition = value.englishDefinition
            model.aiContextExplanation = value.aiContextExplanation
            model.exampleSentence = value.exampleSentence
            model.contextSentence = value.contextSentence
            model.courseID = value.courseID
            model.sourceRecordID = value.sourceRecordID
            model.sourceTypeRaw = value.sourceTypeRaw
            model.tags = value.tags
            model.categoryRaw = value.categoryRaw
            model.importanceRaw = value.importanceRaw
            model.masteryLevelRaw = value.masteryLevelRaw
            // The after-state comparison includes review/lookup fields and dependencies.
            model.reviewIntervalDays = value.reviewIntervalDays
            model.correctStreak = value.correctStreak
            model.reviewCount = value.reviewCount
            model.wrongCount = value.wrongCount
            model.duplicateHitCount = value.duplicateHitCount
            model.lastDuplicateHitAt = value.lastDuplicateHitAt
            model.lastReviewedAt = value.lastReviewedAt
            model.nextReviewAt = value.nextReviewAt
            try touch(model, at: date)
        }
        for value in before.content.candidates {
            guard let model = try undoModels(Candidate.self, matching: \.id, in: [value.id]).first,
                  let state = before.candidateStates.first(where: { $0.id == value.id }) else {
                throw WordNoteV2UndoError.changedSinceSave
            }
            let revision = try increment(model.revision)
            model.term = value.term
            model.normalizedTerm = value.normalizedTerm
            model.termTypeRaw = value.termTypeRaw
            model.needToLearn = value.needToLearn
            model.importanceRaw = value.importanceRaw
            model.categoryRaw = value.categoryRaw
            model.reason = value.reason
            model.chineseMeaning = value.chineseMeaning
            model.englishDefinition = value.englishDefinition
            model.aiContextExplanation = value.aiContextExplanation
            model.exampleSentence = value.exampleSentence
            model.relatedTerms = value.relatedTerms
            model.confidence = value.confidence
            model.statusRaw = value.statusRaw
            state.apply(to: model)
            model.revision = revision
            model.updatedAt = date
        }
        for value in before.content.inputRecords {
            let model = try record(value.id)
            // Editing/confirmation only changes curation status and revision on the source.
            model.statusRaw = value.statusRaw
            model.revision = try increment(model.revision)
            model.updatedAt = date
        }

        let oldLinks = Dictionary(uniqueKeysWithValues: before.courseLinks.map { ($0.id, $0) })
        let currentLinks = try undoModels(CourseLink.self, matching: \.termID, in: Array(scope.terms))
        for link in currentLinks where oldLinks[link.id] == nil { context.delete(link) }
        let currentLinkIDs = Set(currentLinks.map(\.id))
        for value in before.courseLinks where !currentLinkIDs.contains(value.id) { context.insert(value.model()) }

        let oldOccurrences = Set(before.occurrences.map(\.id))
        let currentOccurrences = try undoModels(Occurrence.self, matching: \.termID, in: Array(scope.terms))
        for occurrence in currentOccurrences where !oldOccurrences.contains(occurrence.id) { context.delete(occurrence) }
        let currentOccurrenceIDs = Set(currentOccurrences.map(\.id))
        for value in before.occurrences where !currentOccurrenceIDs.contains(value.id) { context.insert(try value.model()) }

        // Only entities created by the exact recorded operation may disappear. No general cascade.
        for id in scope.terms.subtracting(oldTermIDs) { context.delete(try term(id)) }
        for id in scope.courses.subtracting(oldCourseIDs) { context.delete(try course(id)) }
    }
}
