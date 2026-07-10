import Foundation

public struct VocabularyCompletion: Equatable, Sendable {
    public let completedText: String
    public let suffix: String

    public init(completedText: String, suffix: String) {
        self.completedText = completedText
        self.suffix = suffix
    }
}

public enum VocabularyCompletionMatcher {
    public static let minimumPrefixLength = 2

    public static func bestCompletion(
        for input: String,
        candidates: [String]
    ) -> VocabularyCompletion? {
        guard input.count >= minimumPrefixLength,
              input.first?.isWhitespace != true,
              !input.contains(where: \Character.isNewline) else {
            return nil
        }

        return candidates
            .compactMap { completion(for: input, candidate: $0) }
            .min(by: isPreferred)
    }

    private static func completion(for input: String, candidate: String) -> VocabularyCompletion? {
        guard let prefixRange = candidate.range(
            of: input,
            options: [.anchored, .caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ), prefixRange.upperBound < candidate.endIndex else {
            return nil
        }

        let suffix = String(candidate[prefixRange.upperBound...])
        guard !suffix.isEmpty else { return nil }

        return VocabularyCompletion(
            completedText: input + suffix,
            suffix: suffix
        )
    }

    private static func isPreferred(
        _ lhs: VocabularyCompletion,
        _ rhs: VocabularyCompletion
    ) -> Bool {
        if lhs.suffix.count != rhs.suffix.count {
            return lhs.suffix.count < rhs.suffix.count
        }

        let lhsKey = sortKey(lhs.completedText)
        let rhsKey = sortKey(rhs.completedText)
        if lhsKey != rhsKey {
            return lhsKey < rhsKey
        }
        return lhs.completedText < rhs.completedText
    }

    private static func sortKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
