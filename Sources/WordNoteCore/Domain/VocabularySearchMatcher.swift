import Foundation

public enum VocabularySearchMatcher {
    public struct Query: Equatable, Sendable {
        fileprivate let isBlank: Bool
        fileprivate let english: String
        fileprivate let chinese: String

        public init(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            isBlank = trimmed.isEmpty
            english = TextNormalizer.normalized(trimmed)
            chinese = VocabularySearchMatcher.chineseSearchKey(trimmed)
        }
    }

    public struct Entry: Equatable, Sendable {
        private let term: String
        private let english: String?
        private let chinese: String?

        public init(term: String, chineseMeaning: String?, englishDefinition: String?) {
            self.term = TextNormalizer.normalized(term)
            english = englishDefinition.map(TextNormalizer.normalized)
            chinese = chineseMeaning.map(VocabularySearchMatcher.chineseSearchKey)
        }

        public func matches(_ query: Query) -> Bool {
            if query.isBlank { return true }
            if term.contains(query.english) || english?.contains(query.english) == true { return true }
            return !query.chinese.isEmpty && chinese?.contains(query.chinese) == true
        }
    }

    public static func matches(
        query: String,
        term: String,
        chineseMeaning: String?,
        englishDefinition: String?
    ) -> Bool {
        // Callers without a reusable index must not normalize every definition for an empty or English hit.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let english = TextNormalizer.normalized(trimmed)
        if TextNormalizer.normalized(term).contains(english) { return true }
        if englishDefinition.map({ TextNormalizer.normalized($0).contains(english) }) == true { return true }
        let chinese = chineseSearchKey(trimmed)
        guard !chinese.isEmpty, let chineseMeaning else { return false }
        return chineseSearchKey(chineseMeaning).contains(chinese)
    }

    private static func chineseSearchKey(_ value: String) -> String {
        let simplified = value.applyingTransform(
            StringTransform("Hant-Hans"),
            reverse: false
        ) ?? value

        return simplified
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "zh_Hans")
            )
    }
}
