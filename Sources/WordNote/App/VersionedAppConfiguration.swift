import WordNoteCore

#if WORDNOTE_V2_VALIDATION && WORDNOTE_V3_VALIDATION
#error("Choose exactly one validation schema.")
#endif

#if WORDNOTE_V3_VALIDATION
typealias AppSchema = WordNoteSchemaV3
typealias AppContentService = WordNoteV3ContentService
typealias AppContentError = WordNoteV3ContentError
typealias AppUndoHistory = WordNoteV3UndoHistory
typealias QuickAddAnalysisQueue = WordNoteV3AnalysisQueue
typealias AppAnalysisJob = WordNoteV3AnalysisJob
#else
typealias AppSchema = WordNoteSchemaV2
typealias AppContentService = WordNoteV2ContentService
typealias AppContentError = WordNoteV2ContentError
typealias AppUndoHistory = WordNoteV2UndoHistory
typealias AppAnalysisJob = WordNoteV2AnalysisJob
#if WORDNOTE_V2_VALIDATION
typealias QuickAddAnalysisQueue = WordNoteV2AnalysisQueue
#endif
#endif

enum VersionedAppConfiguration {
    #if WORDNOTE_V3_VALIDATION
    static let schema: WordNoteDataSchemaVersion = .v3
    static let title = "Word Note V3 QA"
    static let version = "V3-QA"
    static let launchFlag = "--ui-v3-fixture"
    #else
    static let schema: WordNoteDataSchemaVersion = .v2
    static let title = "Word Note V2 QA"
    static let version = "V2-QA"
    static let launchFlag = "--ui-v2-fixture"
    #endif
}
