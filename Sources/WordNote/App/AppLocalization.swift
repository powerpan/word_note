import Foundation
import WordNoteCore

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    static func resolve(preferredLanguages: [String]) -> AppLanguage {
        let preferred = Bundle.preferredLocalizations(
            from: allCases.map(\.rawValue), forPreferences: preferredLanguages
        ).first
        return preferred.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }
}

extension InboxBrowseItem {
    var localizedPreview: String { previewText ?? AppLocalization.text(statusTitle) }
}

enum AppLocalization {
    static let language = AppLanguage.resolve(preferredLanguages: Locale.preferredLanguages)

    // Only UI-owned strings pass through here. User content stays verbatim.
    static func text(_ key: String) -> String {
        #if WORDNOTE_V3_VALIDATION
        return text(key, language: language)
        #else
        return key
        #endif
    }

    static func text(_ key: String, language: AppLanguage) -> String {
        bundle(for: language).localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    static func bundle(for language: AppLanguage) -> Bundle {
        guard let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return Bundle.module }
        return bundle
    }
}
