import Foundation

public struct FloatingExplanationRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let source: String
    public let meaning: String
    public let isMuted: Bool

    public var englishText: String? {
        LookupDirectionDetector.isEnglishVocabularyTerm(source) ? source : nil
    }
}

public extension AIExplanationPreview {
    var floatingRows: [FloatingExplanationRow] {
        floatingRows(direction: LookupDirectionDetector.detect(rawText))
    }

    func floatingRows(direction: LookupDirection) -> [FloatingExplanationRow] {
        var rows: [FloatingExplanationRow] = []

        if let sentenceMeaning {
            // Chinese queries store the English sentence translation in sentenceMeaning.
            if direction == .chineseToEnglish {
                if LookupDirectionDetector.isEnglishVocabularyTerm(sentenceMeaning) {
                    rows.append(FloatingExplanationRow(
                        id: "sentence", source: sentenceMeaning, meaning: rawText, isMuted: false
                    ))
                }
            } else if LookupDirectionDetector.isEnglishVocabularyTerm(rawText) {
                rows.append(FloatingExplanationRow(
                    id: "sentence", source: rawText, meaning: sentenceMeaning, isMuted: false
                ))
            }
        }

        for (index, candidate) in candidates.enumerated() {
            let source = direction == .englishToChinese && sentenceMeaning == nil && candidates.count == 1
                && LookupDirectionDetector.isEnglishVocabularyTerm(rawText)
                ? rawText : candidate.term
            rows.append(FloatingExplanationRow(
                id: "candidate-\(index)-\(candidate.id)", source: source,
                meaning: candidate.chineseMeaning ?? "這次分析沒有返回可顯示的中文釋義。",
                isMuted: candidate.chineseMeaning == nil
            ))
        }

        if rows.isEmpty {
            rows.append(FloatingExplanationRow(
                id: "empty", source: rawText,
                meaning: "這次分析沒有返回可顯示的中文釋義。", isMuted: true
            ))
        }
        return rows
    }
}
