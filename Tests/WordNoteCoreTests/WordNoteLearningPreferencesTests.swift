import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteLearningPreferencesTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "WordNoteLearningPreferencesTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    func testMissingValuesUseVersionedDefaults() throws {
        XCTAssertEqual(try WordNoteLearningPreferences.capture(from: defaults), .init())
        XCTAssertNoThrow(try WordNoteLearningPreferences().validate(courseIDs: []))
    }

    func testOnlyDurableDefaultsAreCapturedNotCurrentOverridesOrDeviceSettings() throws {
        let first = UUID(), other = UUID()
        let context = CaptureContextController(preferences: defaults, availableCourseIDs: [first, other])
        try context.updateDefaults(.init(courseID: first, sourceType: .book, intent: .chineseToEnglish))
        try context.selectCourse(other)
        context.selectIntent(.englishToChinese)
        defaults.set(35, forKey: WordNoteLearningPreferences.targetStorageKey)
        defaults.set(7, forKey: WordNoteLearningPreferences.newLimitStorageKey)
        defaults.set("device-only-test-value", forKey: "captureShortcut")
        defaults.set(true, forKey: CommandShortcutPreference.storageKey)
        defaults.set("synthetic-placeholder", forKey: "DEEPSEEK_API_KEY")
        let captured = try WordNoteLearningPreferences.capture(from: defaults)
        XCTAssertEqual(captured, .init(defaultCourseID: first, defaultLookupIntent: .chineseToEnglish,
            reviewTargetCards: 35, reviewDailyNewLimit: 7))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(captured)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "defaultCourseID", "defaultLookupIntent", "reviewTargetCards", "reviewDailyNewLimit"])
        XCTAssertEqual(context.current.courseID, other)
        XCTAssertEqual(context.current.intent, .englishToChinese)
    }

    func testApplyRoundTripAndRestartUseRestoredDefaultsWithoutChangingOtherPreferences() throws {
        let course = UUID()
        let value = WordNoteLearningPreferences(defaultCourseID: course, defaultLookupIntent: .englishToChinese,
            reviewTargetCards: 100, reviewDailyNewLimit: 0)
        defaults.set("paper", forKey: CaptureContextController.sourceStorageKey)
        defaults.set("device-shortcut", forKey: "captureShortcut")
        defaults.set(false, forKey: CommandShortcutPreference.storageKey)
        try value.apply(to: defaults, courseIDs: [course])
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(try WordNoteLearningPreferences.capture(from: reopened), value)
        let context = CaptureContextController(preferences: reopened, availableCourseIDs: [course])
        XCTAssertEqual(context.current, .init(courseID: course, sourceType: .paper, intent: .englishToChinese))
        XCTAssertEqual(reopened.string(forKey: "captureShortcut"), "device-shortcut")
        XCTAssertFalse(CommandShortcutPreference.isEnabled(in: reopened))
    }

    func testInvalidVersionLimitsAndCourseReferenceFailBeforeWritingDefaults() throws {
        let original = WordNoteLearningPreferences(reviewTargetCards: 35)
        try original.apply(to: defaults, courseIDs: [])
        let mutations: [(inout WordNoteLearningPreferences) -> Void] = [
            { $0.version = 0 }, { $0.version = 2 }, { $0.reviewTargetCards = 4 },
            { $0.reviewTargetCards = 101 }, { $0.reviewDailyNewLimit = -1 },
            { $0.reviewDailyNewLimit = 51 }, { $0.defaultCourseID = UUID() }
        ]
        for mutate in mutations {
            var invalid = original
            mutate(&invalid)
            XCTAssertThrowsError(try invalid.apply(to: defaults, courseIDs: []))
            XCTAssertEqual(try WordNoteLearningPreferences.capture(from: defaults), original)
        }
    }

    func testMalformedLocalValuesNeverSilentlyCoerceToDefaults() throws {
        let key = WordNoteLearningPreferences.targetStorageKey
        for value: Any in [true, "20", 5.5, -1, 101] {
            defaults.set(value, forKey: key)
            XCTAssertThrowsError(try WordNoteLearningPreferences.capture(from: defaults))
        }
        defaults.removeObject(forKey: key)
        for value: Any in ["not-data", Data("{}".utf8), Data("{\"version\":2,\"intent\":\"auto\"}".utf8),
                           Data("{\"version\":1,\"intent\":\"unknown\"}".utf8)] {
            defaults.set(value, forKey: CaptureContextController.storageKey)
            XCTAssertThrowsError(try WordNoteLearningPreferences.capture(from: defaults))
        }
    }

    func testExistingCaptureDefaultsEncodingRemainsCompatible() throws {
        let course = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "courseID": course.uuidString, "intent": "chineseToEnglish"])
        defaults.set(data, forKey: CaptureContextController.storageKey)
        let value = try WordNoteLearningPreferences.capture(from: defaults)
        XCTAssertEqual(value.defaultCourseID, course)
        XCTAssertEqual(value.defaultLookupIntent, .chineseToEnglish)
        try value.apply(to: defaults, courseIDs: [course])
        let restored = try JSONDecoder().decode(StoredCaptureDefaults.self, from: XCTUnwrap(defaults.data(forKey: CaptureContextController.storageKey)))
        XCTAssertEqual(restored.version, 1)
        XCTAssertEqual(restored.courseID, course)
        XCTAssertEqual(restored.intent, .chineseToEnglish)
    }

    func testRemovedLocalDefaultCourseIsReconciledButImportedReferenceIsRejected() throws {
        let course = UUID()
        let context = CaptureContextController(preferences: defaults, availableCourseIDs: [course])
        try context.updateDefaults(.init(courseID: course, intent: .chineseToEnglish))
        let saved = try WordNoteLearningPreferences.capture(from: defaults)
        context.reconcileCourses([])
        let reconciled = try WordNoteLearningPreferences.capture(from: defaults)
        XCTAssertNil(reconciled.defaultCourseID)
        XCTAssertEqual(reconciled.defaultLookupIntent, .chineseToEnglish)
        XCTAssertNotNil(context.courseWarning)
        XCTAssertThrowsError(try saved.validate(courseIDs: []))
    }
}
