public enum LookupDirection: String, Codable, CaseIterable, Sendable {
    case englishToChinese
    case chineseToEnglish

    public var displayTitle: String {
        switch self {
        case .englishToChinese:
            "English to Chinese"
        case .chineseToEnglish:
            "Chinese to English"
        }
    }
}

public enum LookupDirectionDetector {
    public static func detect(_ text: String) -> LookupDirection {
        let scalars = text.unicodeScalars
        let hanCount = scalars.filter(isHan).count
        let latinLetterCount = scalars.filter(isASCIILetter).count

        guard hanCount > 0 else { return .englishToChinese }
        guard latinLetterCount > 0 else { return .chineseToEnglish }
        return hanCount >= latinLetterCount ? .chineseToEnglish : .englishToChinese
    }

    public static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isHan)
    }

    public static func isEnglishVocabularyTerm(_ text: String) -> Bool {
        !containsHan(text) && text.unicodeScalars.contains(where: isASCIILetter)
    }

    private static func isASCIILetter(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A:
            true
        default:
            false
        }
    }

    private static func isHan(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2FA1F,
             0x30000...0x323AF:
            true
        default:
            false
        }
    }
}
