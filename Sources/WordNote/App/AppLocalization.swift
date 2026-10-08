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

    static func dataNotice(_ notice: WordNoteDataNotice, language: AppLanguage? = nil) -> String {
        func localized(_ key: String) -> String {
            language.map { text(key, language: $0) } ?? text(key)
        }
        switch notice {
        case .message(let message): return localized(message)
        case .automaticBackupFailed(let diagnostic):
            return String(format: localized("Automatic backup failed: %@"), diagnostic)
        case .vocabularyExported(let count):
            return String(format: localized("Exported %lld vocabulary entries."), count)
        case .analysisResumed(let count):
            return String(format: localized("Resumed %lld pending analysis requests."), count)
        }
    }

    static func shortcutError(_ error: any Error, language: AppLanguage? = nil) -> String {
        func localized(_ key: String) -> String {
            language.map { text(key, language: $0) } ?? text(key)
        }
        switch error as? CaptureShortcutError {
        case .registrationFailed(let code):
            return String(format: localized("The shortcut could not be registered (macOS error %d). It may be in use by another app."), code)
        case .removalFailed(let code):
            return String(format: localized("The previous shortcut could not be released (macOS error %d). Retry or restart Word Note."), code)
        case .some(let error): return localized(error.localizedDescription)
        case nil: return error.localizedDescription
        }
    }

    static func comparisonTitle(_ row: WordNoteEditDifference, language: AppLanguage? = nil) -> String {
        let title = language.map { text(row.title, language: $0) } ?? text(row.title)
        return row.titleContext.map { "\($0) / \(title)" } ?? title
    }

    static func comparisonValue(_ value: String, in row: WordNoteEditDifference, language: AppLanguage? = nil) -> String {
        guard value.isEmpty || row.localizesValues else { return value }
        let key = value.isEmpty ? "(Empty)" : value
        return language.map { text(key, language: $0) } ?? text(key)
    }

    static func bundle(for language: AppLanguage) -> Bundle {
        guard let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return Bundle.module }
        return bundle
    }
}
