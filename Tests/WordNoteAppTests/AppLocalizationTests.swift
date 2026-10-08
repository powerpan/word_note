import XCTest
import WordNoteCore
@testable import WordNote

final class AppLocalizationTests: XCTestCase {
    func testLanguageUsesSystemPreferenceOrderAndRegionFallback() {
        for identifier in ["zh-CN", "zh-SG", "zh-Hans", "zh-Hans-HK"] {
            XCTAssertEqual(AppLanguage.resolve(preferredLanguages: [identifier]), .simplifiedChinese, identifier)
        }
        for identifier in ["zh-TW", "zh-HK", "zh-MO", "zh-Hant", "zh-Hant-CN"] {
            XCTAssertEqual(AppLanguage.resolve(preferredLanguages: [identifier]), .traditionalChinese, identifier)
        }
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["en-GB", "zh-Hant"]), .english)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["fr", "zh-Hant"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["ja"]), .english)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: []), .english)
    }

    func testAllCatalogsContainTheSameNonemptyKeysAndFormatArguments() throws {
        let english = try catalog(.english)
        XCTAssertGreaterThan(english.count, 650)
        for language in AppLanguage.allCases {
            let translated = try catalog(language)
            XCTAssertEqual(Set(translated.keys), Set(english.keys), language.rawValue)
            for (key, source) in english {
                let value = try XCTUnwrap(translated[key], "\(language): \(key)")
                if !key.isEmpty { XCTAssertFalse(value.isEmpty, "\(language): \(key)") }
                XCTAssertEqual(try arguments(source), try arguments(value), "\(language): \(key)")
            }
        }
    }

    func testResourceLookupAndUnknownKeyFallback() {
        XCTAssertEqual(AppLocalization.text("Settings", language: .english), "Settings")
        XCTAssertEqual(AppLocalization.text("Settings", language: .simplifiedChinese), "设置")
        XCTAssertEqual(AppLocalization.text("Settings", language: .traditionalChinese), "設置")
        XCTAssertEqual(AppLocalization.text("Vocabulary", language: .traditionalChinese), "詞庫")
        for language in AppLanguage.allCases {
            XCTAssertEqual(AppLocalization.text("unknown-diagnostic", language: language), "unknown-diagnostic")
        }
    }

    func testKnownDomainLabelsAreCoveredWithoutChangingStoredValues() throws {
        var labels = SourceType.allCases.map(\.displayTitle)
        labels += TermType.allCases.map(\.displayTitle)
        labels += Importance.allCases.map(\.displayTitle)
        labels += TermCategory.allCases.map(\.displayTitle)
        labels += MasteryLevel.allCases.map(\.displayTitle)
        labels += ReviewMode.allCases.map(\.displayTitle)
        labels += ReviewFeedback.allCases.map(\.displayTitle)
        labels += InputRecordStatus.allCases.map(\.displayTitle)
        labels += ReviewQueueScope.allCases.map(\.displayTitle)
        labels += VocabularySort.allCases.map(\.title)
        labels += VocabularyActivity.allCases.map(\.title)
        labels += InboxStatusFilter.allCases.map(\.title)
        labels += ReviewCardBrowseState.allCases.map(\.title)
        labels += WordNoteV2ConfirmationField.allCases.map(\.title)
        let english = try catalog(.english)
        for label in labels { XCTAssertNotNil(english[label], label) }
        XCTAssertEqual(ReviewMode.englishToChinese.rawValue, "englishToChinese")
        XCTAssertEqual(SourceType.class.rawValue, "class")
        XCTAssertEqual(MasteryLevel.mastered.displayTitle, "Mastered")
    }

    func testFormatArgumentsRemainVerbatimEvenWhenTheyEqualUIKeys() {
        let userText = "Review / Settings / 中文 / 100% / %@"
        for language in AppLanguage.allCases {
            let result = String(format: AppLocalization.text("Term: %@", language: language), userText)
            XCTAssertTrue(result.hasSuffix(userText))
            let numbers = String(format: AppLocalization.text("%lld pending, %lld selected", language: language), 7, 3)
            XCTAssertTrue(numbers.contains("7"))
            XCTAssertTrue(numbers.contains("3"))
            XCTAssertFalse(numbers.contains("%lld"))
        }
    }

    func testDefaultLookupRemainsVersionGated() {
        #if WORDNOTE_V3_VALIDATION
        XCTAssertEqual(AppLocalization.text("Settings"), AppLocalization.text("Settings", language: AppLocalization.language))
        #else
        XCTAssertEqual(AppLocalization.text("Settings"), "Settings")
        #endif
    }

    private func catalog(_ language: AppLanguage) throws -> [String: String] {
        let url = try XCTUnwrap(AppLocalization.bundle(for: language).url(forResource: "Localizable", withExtension: "strings"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }

    private func arguments(_ value: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #"%(?:[0-9]+\$)?(?:lld|ld|d|u|f|@|%)"#)
        return expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
            String(value[Range($0.range, in: value)!])
        }
    }
}
