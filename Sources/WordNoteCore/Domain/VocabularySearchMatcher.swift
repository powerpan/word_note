import Foundation

public enum VocabularySearchMatcher {
    public static func matches(
        query: String,
        term: String,
        chineseMeaning: String?,
        englishDefinition: String?
    ) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return true }

        let normalizedQuery = TextNormalizer.normalized(trimmedQuery)
        if TextNormalizer.normalized(term).contains(normalizedQuery) {
            return true
        }

        if let englishDefinition,
           TextNormalizer.normalized(englishDefinition).contains(normalizedQuery) {
            return true
        }

        let chineseQueryKey = chineseSearchKey(trimmedQuery)
        guard !chineseQueryKey.isEmpty,
              let chineseMeaning else {
            return false
        }

        return chineseSearchKey(chineseMeaning).contains(chineseQueryKey)
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
