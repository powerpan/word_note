public enum LookupIntent: String, Codable, CaseIterable, Sendable {
    case auto
    case englishToChinese
    case chineseToEnglish
}

public enum AnalysisQueueState: String, Codable, CaseIterable, Sendable {
    case none
    case queued
    case running
    case failed
    case cancelled
}

public enum CandidateSavedLinkState: String, Codable, CaseIterable, Sendable {
    case none
    case resolved
    case unresolvedLegacy
    case targetDeleted
}

public enum TermCounterSemanticsVersion: String, Codable, CaseIterable, Sendable {
    case legacyMixed
}

public enum CaptureSurface: String, Codable, CaseIterable, Sendable {
    case legacy
    case mainQuickAdd
    case floatingQuickAdd
    case manual
}

public enum LookupEventKind: String, Codable, CaseIterable, Sendable {
    case exactRepeat
}

/// Frozen baseline for migration and retries; future heuristics need a new version.
public enum LookupDirectionDetectorV1 {
    public static let version = "han-latin-v1"

    public static func detect(_ text: String) -> LookupDirection {
        var hanCount = 0
        var latinCount = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A:
                latinCount += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2FA1F, 0x30000...0x323AF:
                hanCount += 1
            default:
                break
            }
        }
        return hanCount > 0 && hanCount >= latinCount ? .chineseToEnglish : .englishToChinese
    }
}
