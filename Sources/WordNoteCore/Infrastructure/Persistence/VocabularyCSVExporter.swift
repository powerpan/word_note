import Foundation

public enum VocabularyCSVExporter {
    public static func export(
        terms: [WordNoteSnapshotPayload.Term], courses: [WordNoteSnapshotPayload.Course]
    ) -> Data {
        let courseNames = Dictionary(courses.map { ($0.id, $0.courseName) }, uniquingKeysWith: { first, _ in first })
        let formatter = ISO8601DateFormatter()
        let header = ["English", "Chinese", "English Definition", "Course", "Tags", "Source", "Category", "Importance", "Mastery", "Next Review"]
        let rows = terms.map { term -> [String] in
            [
                term.term, term.chineseMeaning ?? "", term.englishDefinition ?? "",
                term.courseID.flatMap { courseNames[$0] } ?? "", term.tags.joined(separator: "; "),
                term.sourceTypeRaw, term.categoryRaw, term.importanceRaw, term.masteryLevelRaw,
                term.nextReviewAt.map(formatter.string) ?? ""
            ]
        }
        let csv = ([header] + rows).map { $0.map(escapeCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        return Data(csv.utf8)
    }

    static func escapeCell(_ value: String) -> String {
        let scalars = value.unicodeScalars
        let firstSignificant = scalars.first {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.controlCharacters.contains($0)
                && $0.value != 0xFEFF && $0.value != 0x200B
        }
        let dangerousPrefix = firstSignificant.map { "=+-@".unicodeScalars.contains($0) } ?? false
        let leadingControl = scalars.first.map { CharacterSet.controlCharacters.contains($0) } ?? false
        let readable = scalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar), ![9, 10, 13].contains(scalar.value) {
                return String(format: "\\u{%04X}", scalar.value)
            }
            return String(scalar)
        }.joined()
        let safeText = (dangerousPrefix || leadingControl ? "'" : "") + readable
        return "\"" + safeText.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
