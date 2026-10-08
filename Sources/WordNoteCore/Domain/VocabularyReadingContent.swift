import Foundation

public struct VocabularyReadingContent: Sendable {
    public struct Section: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let text: String
    }

    public let meanings: [Section]
    public let sources: [Section]
    public let source: WordNoteSnapshotV2Payload.Occurrence?

    public init(term: WordNoteSnapshotPayload.Term, occurrences: [WordNoteSnapshotV2Payload.Occurrence]) {
        meanings = [
            Self.section("chinese", "Chinese Meaning", term.chineseMeaning),
            Self.section("english", "English Definition", term.englishDefinition),
            Self.section("technical", "Technical Meaning", term.aiContextExplanation),
            Self.section("example", "Example", term.exampleSentence)
        ].compactMap { $0 }
        let matching = occurrences.filter { $0.termID == term.id }.sorted {
            $0.occurredAt == $1.occurredAt ? $0.id.uuidString < $1.id.uuidString : $0.occurredAt > $1.occurredAt
        }
        let primary = term.sourceRecordID.flatMap { id in matching.first { $0.sourceRecordID == id } }
        source = primary ?? matching.first
        var sections: [Section] = []
        if let source {
            if let input = Self.section("input", primary == nil ? "Latest Captured Input" : "Captured Input", source.rawTextSnapshot) {
                sections.append(input)
            }
            if let note = Self.section("note", "Source Note", source.note) { sections.append(note) }
        }
        if term.contextSentence != source?.rawTextSnapshot,
           let context = Self.section("context", "Saved Context", term.contextSentence) {
            sections.append(context)
        }
        sources = sections
    }

    private static func section(_ id: String, _ title: String, _ text: String?) -> Section? {
        guard let text, !TextNormalizer.isBlank(text) else { return nil }
        return .init(id: id, title: title, text: text)
    }
}
