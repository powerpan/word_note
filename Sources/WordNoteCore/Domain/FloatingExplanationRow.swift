import Foundation

public struct FloatingExplanationRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let source: String
    public let meaning: String
    public let isMuted: Bool
}

public extension AIExplanationPreview {
    var floatingRows: [FloatingExplanationRow] {
        let direction = LookupDirectionDetector.detect(rawText)
        var rows: [FloatingExplanationRow] = []

        if let sentenceMeaning {
            // Chinese queries store the English sentence translation in sentenceMeaning.
            if direction == .chineseToEnglish {
                if LookupDirectionDetector.isEnglishVocabularyTerm(sentenceMeaning) {
                    rows.append(FloatingExplanationRow(
                        id: "sentence", source: sentenceMeaning, meaning: rawText, isMuted: false
                    ))
                }
            } else {
                rows.append(FloatingExplanationRow(
                    id: "sentence", source: rawText, meaning: sentenceMeaning, isMuted: false
                ))
            }
        }

        for (index, candidate) in candidates.enumerated() {
            let source = direction == .englishToChinese && sentenceMeaning == nil && candidates.count == 1
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
