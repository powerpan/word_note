import SwiftData
import SwiftUI
import WordNoteCore

#if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
typealias CourseModel = AppSchema.CourseModel
typealias TermModel = AppSchema.TermModel
typealias InputRecordModel = AppSchema.InputRecordModel
typealias CandidateTermModel = AppSchema.CandidateTermModel

extension QuickAddAnalysisQueue {
    func enqueue(rawText: String, courseID: UUID?, courseName: String?, sourceType: SourceType, note: String?, capturedVia: CaptureSurface = .mainQuickAdd) throws {
        _ = try enqueue(WordNoteCaptureRequest(rawText: rawText, courseID: courseID, sourceType: sourceType, note: note, capturedVia: capturedVia))
    }
}

@MainActor
struct InputRecordService {
    let modelContext: ModelContext
    func ignore(_ record: InputRecordModel) throws {
        try AppContentService(container: modelContext.container).ignoreInputRecord(record.id, expectedRevision: record.revision)
    }
    func delete(_ record: InputRecordModel) throws {
        try AppContentService(container: modelContext.container).deleteInputRecord(record.id, expectedRevision: record.revision)
    }
}

struct CandidateConfirmation {
    let candidates: [CandidateTermModel]
    let sourceRecord: InputRecordModel
    var selections: [WordNoteV2CandidateSelection] {
        candidates.map { .init(id: $0.id, revision: $0.revision, recordID: sourceRecord.id, recordRevision: sourceRecord.revision) }
    }
}

@MainActor
struct VocabularyService {
    let modelContext: ModelContext
    var expectedRevision: Int? = nil
    var courseIDs: Set<UUID>? = nil
    var undoHistory: AppUndoHistory? = nil

    func createTerms(from candidates: [CandidateTermModel], sourceRecord: InputRecordModel) throws -> [TermModel] {
        try confirmCandidates([CandidateConfirmation(candidates: candidates, sourceRecord: sourceRecord)])
    }
    func confirmCandidates(_ confirmations: [CandidateConfirmation]) throws -> [TermModel] {
        let result = try AppContentService(container: modelContext.container, undoHistory: undoHistory)
            .confirmNewCandidates(confirmations.flatMap(\.selections))
        let ids = Set(result.map(\.id))
        return try modelContext.fetch(FetchDescriptor<TermModel>()).filter { ids.contains($0.id) }
    }
    func ignore(_ candidates: [CandidateTermModel], sourceRecord: InputRecordModel) throws {
        try AppContentService(container: modelContext.container)
            .ignoreCandidates(CandidateConfirmation(candidates: candidates, sourceRecord: sourceRecord).selections)
    }
    func createManualTerm(termText: String, chineseMeaning: String?, englishDefinition: String?, sourceRecord: InputRecordModel) throws -> TermModel {
        let result = try AppContentService(container: modelContext.container, undoHistory: undoHistory).createManualTerm(
            sourceRecordID: sourceRecord.id, expectedRecordRevision: expectedRevision ?? sourceRecord.revision,
            termText: termText, chineseMeaning: chineseMeaning, englishDefinition: englishDefinition
        )
        guard let value = try modelContext.fetch(FetchDescriptor<TermModel>()).first(where: { $0.id == result.id }) else {
            throw AppContentError.missingEntity
        }
        return value
    }
    func updateTerm(
        _ term: TermModel, termText: String, termType: TermType, chineseMeaning: String?, englishDefinition: String?,
        aiContextExplanation: String?, exampleSentence: String?, contextSentence: String?, courseID: UUID?,
        sourceType: SourceType, category: TermCategory, importance: Importance, masteryLevel: MasteryLevel
    ) throws {
        guard let expectedRevision, let courseIDs else { throw AppContentError.invalidState }
        try AppContentService(container: modelContext.container, undoHistory: undoHistory).updateTerm(
            term.id, expectedRevision: expectedRevision, termText: termText, termType: termType,
            chineseMeaning: chineseMeaning, englishDefinition: englishDefinition, aiContextExplanation: aiContextExplanation,
            exampleSentence: exampleSentence, contextSentence: contextSentence, courseIDs: courseIDs, sourceType: sourceType,
            category: category, importance: importance, masteryLevel: masteryLevel
        )
    }
    func delete(_ term: TermModel) throws {
        try AppContentService(container: modelContext.container).deleteTerm(term.id, expectedRevision: expectedRevision ?? term.revision)
    }
}

@MainActor
struct CourseService {
    let modelContext: ModelContext
    var expectedRevision: Int? = nil
    var undoHistory: AppUndoHistory? = nil
    func create(courseName: String, courseCode: String?, instructor: String?, semester: String?, description: String?) throws -> CourseModel {
        let result = try AppContentService(container: modelContext.container, undoHistory: undoHistory).createCourse(
            courseName: courseName, courseCode: courseCode, instructor: instructor, semester: semester, description: description
        )
        guard let value = try modelContext.fetch(FetchDescriptor<CourseModel>()).first(where: { $0.id == result.id }) else {
            throw AppContentError.missingEntity
        }
        return value
    }
    func update(_ course: CourseModel, courseName: String, courseCode: String?, instructor: String?, semester: String?, description: String?) throws {
        guard let expectedRevision else { throw AppContentError.invalidState }
        try AppContentService(container: modelContext.container, undoHistory: undoHistory).updateCourse(
            course.id, expectedRevision: expectedRevision, courseName: courseName, courseCode: courseCode,
            instructor: instructor, semester: semester, description: description
        )
    }
    func delete(_ course: CourseModel) throws {
        try AppContentService(container: modelContext.container).deleteCourse(course.id, expectedRevision: expectedRevision ?? course.revision)
    }
}

#if !WORDNOTE_V3_VALIDATION
@MainActor
struct ReviewService {
    let modelContext: ModelContext
    func recordFeedback(for term: TermModel, mode: ReviewMode, feedback: ReviewFeedback) throws {
        try AppContentService(container: modelContext.container).recordLegacyFeedback(
            termID: term.id, expectedRevision: term.revision, mode: mode, feedback: feedback
        )
    }
    func postponeUntilTomorrow(_ term: TermModel) throws {
        try AppContentService(container: modelContext.container).postponeLegacyReview(termID: term.id, expectedRevision: term.revision)
    }
}
#endif
#else
extension QuickAddAnalysisQueue {
    func enqueue(rawText: String, courseID: UUID?, courseName: String?, sourceType: SourceType, note: String?, capturedVia: CaptureSurface) throws {
        try enqueue(rawText: rawText, courseID: courseID, courseName: courseName, sourceType: sourceType, note: note)
    }
}
extension VocabularyService {
    init(modelContext: ModelContext, expectedRevision: Int, courseIDs: Set<UUID>, undoHistory: AppUndoHistory? = nil) { self.init(modelContext: modelContext) }
    init(modelContext: ModelContext, undoHistory: AppUndoHistory?) { self.init(modelContext: modelContext) }
}
extension CourseService {
    init(modelContext: ModelContext, expectedRevision: Int, undoHistory: AppUndoHistory? = nil) { self.init(modelContext: modelContext) }
}
#endif

extension TermModel {
    var editRevision: Int {
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        revision
        #else
        0
        #endif
    }
}
extension CourseModel {
    var editRevision: Int {
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        revision
        #else
        0
        #endif
    }
}
extension InputRecordModel {
    var resolvedDirection: LookupDirection {
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        LookupDirection(rawValue: resolvedLookupDirectionRaw) ?? .englishToChinese
        #else
        LookupDirectionDetector.detect(rawText)
        #endif
    }
    var editRevision: Int {
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        revision
        #else
        0
        #endif
    }
    var analysisPending: Bool {
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        queueStateRaw == "queued" || queueStateRaw == "running"
        #else
        status == .analyzing
        #endif
    }
    var analysisFailed: Bool {
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        queueStateRaw == "failed"
        #else
        status == .failed
        #endif
    }
    var visibleStatusTitle: String {
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        switch queueStateRaw {
        case "queued": return AppLocalization.text("Queued")
        case "running": return AppLocalization.text("Analyzing")
        case "failed": return AppLocalization.text("Analysis failed")
        case "cancelled": return AppLocalization.text("Analysis cancelled")
        default: return AppLocalization.text(status.displayTitle)
        }
        #else
        return AppLocalization.text(status.displayTitle)
        #endif
    }
}

@MainActor
struct AppCourseMemberships: DynamicProperty {
    #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
    @Query private var links: [AppSchema.TermCourseLinkModel]
    #endif

    func ids(for term: TermModel) -> Set<UUID> {
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        Set(links.filter { $0.termID == term.id }.map(\.courseID))
        #else
        Set([term.courseID].compactMap { $0 })
        #endif
    }
    func matches(_ term: TermModel, courseID: UUID?) -> Bool { courseID.map { ids(for: term).contains($0) } ?? true }
    func names(for term: TermModel, courses: [CourseModel]) -> String? {
        let ids = ids(for: term)
        let names = courses.filter { ids.contains($0.id) }.map(\.courseName).sorted()
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }
}
