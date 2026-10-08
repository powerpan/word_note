import Foundation

public enum WordNoteTagError: LocalizedError {
    case invalidLabel
    public var errorDescription: String? { "New tags must contain 1-80 characters and no control characters." }
}

public enum WordNoteTags {
    public static let maximumNewTagCharacters = 80

    public static func key(_ value: String) -> String { TextNormalizer.normalized(value) }

    public static func newLabel(_ value: String) throws -> String {
        let label = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !label.isEmpty, label.count <= maximumNewTagCharacters,
              !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw WordNoteTagError.invalidLabel
        }
        return label
    }

    public struct Option: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
    }

    public static func options(_ tags: [String]) -> [Option] {
        let grouped = Dictionary(grouping: tags.filter { !key($0).isEmpty }, by: key)
        return grouped.keys.sorted().map { id in
            let label = grouped[id, default: []].sorted().first ?? id
            return Option(id: id, label: label.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
