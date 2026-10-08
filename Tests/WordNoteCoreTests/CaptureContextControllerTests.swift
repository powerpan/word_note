import XCTest
@testable import WordNoteCore

@MainActor
final class CaptureContextControllerTests: XCTestCase {
    private var suite = ""
    private var preferences: UserDefaults!
    private let first = UUID()
    private let second = UUID()
    private var ids: Set<UUID> { [first, second] }

    override func setUp() async throws {
        suite = "WordNote-Capture-Context-Tests-\(UUID().uuidString)"
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        preferences.removePersistentDomain(forName: suite)
        preferences = nil
    }

    func testFreshContextUsesSafeDefaultsWithoutWritingPreferences() {
        let context = makeContext()
        XCTAssertEqual(context.current, .init())
        XCTAssertEqual(context.defaultContext, .init())
        XCTAssertTrue(context.isUsingDefaults)
        XCTAssertNil(context.preferenceWarning)
        XCTAssertNil(preferences.object(forKey: CaptureContextController.storageKey))
        XCTAssertNil(preferences.object(forKey: CaptureContextController.sourceStorageKey))
    }

    func testExistingDefaultSourceSeedsBothSurfacesWithoutMigration() {
        preferences.set("paper", forKey: CaptureContextController.sourceStorageKey)
        let context = makeContext()
        XCTAssertEqual(context.current.sourceType, .paper)
        XCTAssertEqual(context.defaultContext.sourceType, .paper)
        XCTAssertNil(preferences.object(forKey: CaptureContextController.storageKey))
    }

    func testDefaultsPersistButCurrentOverridesDoNotSurviveRestart() throws {
        let context = makeContext()
        let saved = CaptureContextSelection(courseID: first, sourceType: .book, intent: .chineseToEnglish)
        try context.updateDefaults(saved)
        try context.selectCourse(second)
        context.selectSource(.paper)
        context.selectIntent(.englishToChinese)
        let next = makeContext()
        XCTAssertEqual(next.defaultContext, saved)
        XCTAssertEqual(next.current, saved)
        XCTAssertTrue(next.isUsingDefaults)
        XCTAssertEqual(preferences.string(forKey: CaptureContextController.sourceStorageKey), "book")
    }

    func testCurrentNoCourseRemainsExplicitWhenDefaultsChange() throws {
        let context = makeContext()
        try context.updateDefaults(.init(courseID: first))
        try context.selectCourse(nil)
        try context.updateDefaults(.init(courseID: second, sourceType: .slides, intent: .chineseToEnglish))
        XCTAssertEqual(context.current, .init(sourceType: .slides, intent: .chineseToEnglish))
        XCTAssertFalse(context.isUsingDefaults)
    }

    func testSelectingAnEqualValueStillPinsThatFieldUntilReset() throws {
        let context = makeContext()
        context.selectSource(.other)
        context.selectIntent(.auto)
        try context.updateDefaults(.init(courseID: first, sourceType: .paper, intent: .chineseToEnglish))
        XCTAssertEqual(context.current, .init(courseID: first))
        context.useDefaults()
        XCTAssertEqual(context.current, context.defaultContext)
        XCTAssertTrue(context.isUsingDefaults)
        try context.updateDefaults(.init(courseID: second, sourceType: .book, intent: .englishToChinese))
        XCTAssertEqual(context.current, context.defaultContext)
    }

    func testSettingsNeverOverwriteManuallySelectedFields() throws {
        let context = makeContext()
        try context.selectCourse(first)
        context.selectSource(.assignment)
        context.selectIntent(.englishToChinese)
        let original = context.current
        try context.updateDefaults(.init(courseID: second, sourceType: .book, intent: .chineseToEnglish))
        XCTAssertEqual(context.current, original)
    }

    func testInvalidCourseChangesAreRejectedWithoutMutatingStateOrPreferences() throws {
        let context = makeContext()
        try context.updateDefaults(.init(courseID: first, sourceType: .paper))
        let before = preferences.data(forKey: CaptureContextController.storageKey)
        let current = context.current
        XCTAssertThrowsError(try context.selectCourse(UUID()))
        XCTAssertThrowsError(try context.updateDefaults(.init(courseID: UUID(), sourceType: .book)))
        XCTAssertEqual(context.current, current)
        XCTAssertEqual(context.defaultContext, current)
        XCTAssertTrue(context.isUsingDefaults)
        XCTAssertEqual(preferences.data(forKey: CaptureContextController.storageKey), before)
        XCTAssertEqual(preferences.string(forKey: CaptureContextController.sourceStorageKey), "paper")
    }

    func testCourseCatalogReorderingAndAdditionDoNotChangeSelections() throws {
        let context = makeContext()
        try context.updateDefaults(.init(courseID: first))
        try context.selectCourse(second)
        XCTAssertFalse(context.reconcileCourses([second, UUID(), first]))
        XCTAssertEqual(context.current.courseID, second)
        XCTAssertEqual(context.defaultContext.courseID, first)
        XCTAssertNil(context.courseWarning)
    }

    func testDeletingOnlyCurrentCoursePreservesDefaultAndOtherOverrides() throws {
        let context = makeContext()
        try context.updateDefaults(.init(courseID: first))
        try context.selectCourse(second)
        context.selectSource(.assignment)
        context.selectIntent(.chineseToEnglish)
        XCTAssertTrue(context.reconcileCourses([first]))
        XCTAssertEqual(context.current, .init(sourceType: .assignment, intent: .chineseToEnglish))
        XCTAssertEqual(context.defaultContext.courseID, first)
        XCTAssertNotNil(context.courseWarning)
        XCTAssertFalse(context.reconcileCourses([first]))
        context.useDefaults()
        XCTAssertNil(context.courseWarning)
        XCTAssertEqual(context.current.courseID, first)
    }

    func testDeletingDefaultDoesNotReassignCurrentAndPersistsClearedDefault() throws {
        let context = makeContext()
        try context.updateDefaults(.init(courseID: first, sourceType: .paper, intent: .chineseToEnglish))
        try context.selectCourse(second)
        XCTAssertFalse(context.reconcileCourses([second]))
        XCTAssertNil(context.defaultContext.courseID)
        XCTAssertEqual(context.current.courseID, second)
        XCTAssertNotNil(context.courseWarning)
        let restarted = makeContext()
        XCTAssertNil(restarted.current.courseID)
        XCTAssertEqual(restarted.current.sourceType, .paper)
        XCTAssertEqual(restarted.current.intent, .chineseToEnglish)
    }

    func testMissingCourseAtStartupIsClearedWithVisibleNotice() throws {
        try makeContext().updateDefaults(.init(courseID: first))
        let next = CaptureContextController(preferences: preferences, availableCourseIDs: [second])
        XCTAssertNil(next.current.courseID)
        XCTAssertNil(next.defaultContext.courseID)
        XCTAssertNotNil(next.courseWarning)
        XCTAssertNil(makeContext().defaultContext.courseID)
    }

    func testCourseDeletedJustBeforeSaveRejectsOnceInsteadOfSilentlyChangingContext() throws {
        let context = makeContext()
        try context.selectCourse(first)
        XCTAssertThrowsError(try context.request(rawText: "precision", capturedVia: .floatingQuickAdd, availableCourseIDs: [second])) {
            XCTAssertEqual($0 as? CaptureContextError, .missingCourse)
        }
        XCTAssertNil(context.current.courseID)
        XCTAssertNotNil(context.courseWarning)
        let retry = try context.request(rawText: "precision", capturedVia: .floatingQuickAdd, availableCourseIDs: [second])
        XCTAssertNil(retry.courseID)
        XCTAssertEqual(retry.rawText, "precision")
    }

    func testMalformedUnknownAndWrongTypeDefaultsAreNotOverwrittenAtStartup() throws {
        let values: [Any] = [
            "invalid", Data("invalid".utf8),
            Data(#"{"version":2,"intent":"auto"}"#.utf8),
            Data(#"{"version":1,"intent":"future"}"#.utf8),
            Data(#"{"version":1,"intent":"auto","courseID":"not-a-uuid"}"#.utf8)
        ]
        for value in values {
            preferences.set(value, forKey: CaptureContextController.storageKey)
            preferences.set("book", forKey: CaptureContextController.sourceStorageKey)
            let context = makeContext()
            XCTAssertEqual(context.current, .init(sourceType: .book))
            XCTAssertNotNil(context.preferenceWarning)
            if let data = value as? Data { XCTAssertEqual(preferences.data(forKey: CaptureContextController.storageKey), data) }
            else { XCTAssertEqual(preferences.string(forKey: CaptureContextController.storageKey), "invalid") }
            try context.updateDefaults(.init(courseID: second, sourceType: .paper, intent: .englishToChinese))
            XCTAssertNil(context.preferenceWarning)
            XCTAssertEqual(makeContext().current, context.defaultContext)
        }
    }

    func testInvalidLegacySourceDoesNotDiscardValidAdditionalDefaults() throws {
        try makeContext().updateDefaults(.init(courseID: first, sourceType: .book, intent: .chineseToEnglish))
        preferences.set("unknown-source", forKey: CaptureContextController.sourceStorageKey)
        let context = makeContext()
        XCTAssertEqual(context.current, .init(courseID: first, intent: .chineseToEnglish))
        XCTAssertNotNil(context.preferenceWarning)
        XCTAssertEqual(preferences.string(forKey: CaptureContextController.sourceStorageKey), "unknown-source")
    }

    func testRestoredLegacySourceIsAuthoritativeWithoutOverwritingAdditionalDefaults() throws {
        try makeContext().updateDefaults(.init(courseID: first, sourceType: .book, intent: .chineseToEnglish))
        preferences.set("paper", forKey: CaptureContextController.sourceStorageKey)
        XCTAssertEqual(makeContext().current, .init(courseID: first, sourceType: .paper, intent: .chineseToEnglish))
    }

    func testRequestsFreezeValuesAndKeepIndependentCaptureIDsAndSurfaces() throws {
        let context = makeContext()
        try context.selectCourse(first)
        context.selectSource(.book)
        context.selectIntent(.chineseToEnglish)
        let main = try context.request(rawText: "  精度  ", note: "one", capturedVia: .mainQuickAdd, availableCourseIDs: ids)
        let floating = try context.request(rawText: "準確度", capturedVia: .floatingQuickAdd, availableCourseIDs: ids)
        context.useDefaults()
        XCTAssertEqual(main.courseID, first)
        XCTAssertEqual(main.sourceType, .book)
        XCTAssertEqual(main.intent, .chineseToEnglish)
        XCTAssertEqual(main.rawText, "  精度  ")
        XCTAssertEqual(main.note, "one")
        XCTAssertEqual(main.capturedVia, .mainQuickAdd)
        XCTAssertEqual(floating.courseID, first)
        XCTAssertEqual(floating.intent, main.intent)
        XCTAssertEqual(floating.capturedVia, .floatingQuickAdd)
        XCTAssertNil(floating.note)
        XCTAssertNotEqual(main.captureID, floating.captureID)
    }

    func testDirectionDisplayAndCaptureResolutionUseSameFrozenRule() {
        for text in ["precision", "準確度", "AI 精度", "", "123", "A中"] {
            XCTAssertEqual(LookupIntent.auto.resolvedDirection(for: text), LookupDirectionDetectorV1.detect(text))
            XCTAssertEqual(LookupIntent.englishToChinese.resolvedDirection(for: text), .englishToChinese)
            XCTAssertEqual(LookupIntent.chineseToEnglish.resolvedDirection(for: text), .chineseToEnglish)
        }
    }

    private func makeContext() -> CaptureContextController {
        CaptureContextController(preferences: preferences, availableCourseIDs: ids)
    }
}
