import Foundation

public struct ReviewTextRange: Codable, Equatable, Hashable, Sendable {
    public let start: Int
    public let count: Int

    public init(start: Int, count: Int) { self.start = start; self.count = count }

    public func text(in source: String) throws -> String {
        guard start >= 0, count > 0, start <= source.count, count <= source.count - start else {
            throw ReviewQuestionError.invalidRange
        }
        let lower = source.index(source.startIndex, offsetBy: start)
        let upper = source.index(lower, offsetBy: count)
        return String(source[lower..<upper])
    }
}

public enum ReviewQuestionError: LocalizedError, Equatable {
    case missingAnswer, invalidRange, invalidSource, missingContext, sourceChanged, tooManyMatches

    public var errorDescription: String? {
        switch self {
        case .missingAnswer: "This card does not have a usable answer or prompt."
        case .invalidRange: "Select a complete word or phrase in the original text."
        case .invalidSource: "A cloze card requires a verified original English input."
        case .missingContext: "This input has no English context left after hiding the answer."
        case .sourceChanged: "The original text changed. Create and confirm a new cloze target."
        case .tooManyMatches: "This source contains too many answer matches. Choose a shorter source."
        }
    }
}

public enum ReviewTextMasking {
    public static let marker = "____"
    public static let maximumMatches = 1_000

    public static func ranges(in source: String, forms: [String]) throws -> [ReviewTextRange] {
        let normalized = source.precomposedStringWithCanonicalMapping
        guard normalized.count == source.count, source.count <= WordNoteSnapshotPayload.maximumTextCharacters,
              forms.count <= 102 else { throw ReviewQuestionError.invalidRange }
        var ranges = Set<ReviewTextRange>()
        var boundaries: [Int: Int] = [0: 0], utf16Count = 0
        for (index, character) in normalized.enumerated() {
            utf16Count += String(character).utf16.count
            boundaries[utf16Count] = index + 1
        }
        // Latin boundaries allow an English headword embedded in a Chinese definition to be hidden too.
        let boundary = "[\\p{Latin}\\p{M}\\p{N}_+#\\-\u{2010}\u{2011}]"
        let word = "[\\p{Latin}\\p{M}\\p{N}]", apostrophe = "['\u{2019}]"
        for form in Set(forms.map { $0.precomposedStringWithCanonicalMapping }) where !TextNormalizer.isBlank(form) {
            guard form.count <= WordNoteSnapshotPayload.maximumTextCharacters else { throw ReviewQuestionError.invalidRange }
            let body = form.split(whereSeparator: \.isWhitespace).map { word in
                word.map { character -> String in
                    switch character {
                    case "-", "\u{2010}", "\u{2011}": return "[\\-\u{2010}\u{2011}]"
                    case "'", "\u{2019}": return "['\u{2019}]"
                    default: return NSRegularExpression.escapedPattern(for: String(character))
                    }
                }.joined()
            }.joined(separator: "\\s+")
            let expression = try NSRegularExpression(pattern: "(?<!\(boundary))(?<!\(word)\(apostrophe))\(body)(?!\(boundary))(?!\(apostrophe)\(word))",
                options: [.caseInsensitive])
            var failure: ReviewQuestionError?
            expression.enumerateMatches(in: normalized, range: NSRange(location: 0, length: utf16Count)) { match, _, stop in
                guard let match else { return }
                guard let start = boundaries[match.range.location], let end = boundaries[NSMaxRange(match.range)] else {
                    failure = .invalidRange
                    stop.pointee = true
                    return
                }
                ranges.insert(.init(start: start, count: end - start))
                if ranges.count > maximumMatches { failure = .tooManyMatches; stop.pointee = true }
            }
            if let failure { throw failure }
        }
        return ranges.sorted { $0.start == $1.start ? $0.count > $1.count : $0.start < $1.start }
    }

    public static func mask(_ source: String, ranges: [ReviewTextRange]) throws -> String {
        guard ranges.count <= maximumMatches else { throw ReviewQuestionError.tooManyMatches }
        let characters = Array(source)
        var merged: [ReviewTextRange] = []
        for range in ranges.sorted(by: { $0.start == $1.start ? $0.count > $1.count : $0.start < $1.start }) {
            guard range.start >= 0, range.count > 0, range.start <= characters.count,
                  range.count <= characters.count - range.start else { throw ReviewQuestionError.invalidRange }
            if let previous = merged.last, range.start < previous.start + previous.count {
                merged[merged.count - 1] = .init(start: previous.start, count: max(previous.start + previous.count, range.start + range.count) - previous.start)
            } else { merged.append(range) }
        }
        var result = "", cursor = 0
        for range in merged {
            result += String(characters[cursor..<range.start]) + marker
            cursor = range.start + range.count
        }
        result += String(characters[cursor...])
        return result
    }

    public static func mask(_ source: String, forms: [String]) throws -> String {
        try mask(source, ranges: ranges(in: source, forms: forms))
    }
}
