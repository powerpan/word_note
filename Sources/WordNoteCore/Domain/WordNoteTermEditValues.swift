import Foundation

public struct WordNoteTermEditValues: Equatable, Sendable {
    public var termText: String
    public var termType: TermType
    public var chineseMeaning: String
    public var englishDefinition: String
    public var aiContextExplanation: String
    public var exampleSentence: String
    public var contextSentence: String
    public var courseID: UUID?
    public var courseIDs: Set<UUID>
    public var sourceType: SourceType
    public var category: TermCategory
    public var importance: Importance
    public var masteryLevel: MasteryLevel

    public init(
        termText: String = "", termType: TermType = .word, chineseMeaning: String = "", englishDefinition: String = "",
        aiContextExplanation: String = "", exampleSentence: String = "", contextSentence: String = "",
        courseID: UUID? = nil, courseIDs: Set<UUID> = [], sourceType: SourceType = .other,
        category: TermCategory = .general, importance: Importance = .medium, masteryLevel: MasteryLevel = .new
    ) {
        self.termText = termText; self.termType = termType
        self.chineseMeaning = chineseMeaning; self.englishDefinition = englishDefinition
        self.aiContextExplanation = aiContextExplanation; self.exampleSentence = exampleSentence
        self.contextSentence = contextSentence; self.courseID = courseID; self.courseIDs = courseIDs
        self.sourceType = sourceType; self.category = category; self.importance = importance; self.masteryLevel = masteryLevel
    }

    public var preview: String {
        [termText, chineseMeaning, englishDefinition, aiContextExplanation, exampleSentence, contextSentence]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public static func comparisonFields(courseNames: [UUID: String]) -> [WordNoteEditField<Self>] {
        [
            .init("term", title: "Term", keyPath: \.termText, display: { $0 }),
            .init("type", title: "Type", localizesValues: true, keyPath: \.termType, display: { $0.displayTitle }),
            .init("chinese", title: "Chinese", keyPath: \.chineseMeaning, display: { $0 }),
            .init("english", title: "English", keyPath: \.englishDefinition, display: { $0 }),
            .init("technical", title: "AI / CS Context", keyPath: \.aiContextExplanation, display: { $0 }),
            .init("example", title: "Example", keyPath: \.exampleSentence, display: { $0 }),
            .init("context", title: "Original Context", keyPath: \.contextSentence, display: { $0 }),
            .init("courses", title: "Courses", keyPath: \.courseIDs, display: { ids in
                ids.map { courseNames[$0] ?? "Missing course [\($0.uuidString.prefix(8))]" }.sorted().joined(separator: "\n")
            }),
            .init("source", title: "Source", localizesValues: true, keyPath: \.sourceType, display: { $0.displayTitle }),
            .init("category", title: "Category", localizesValues: true, keyPath: \.category, display: { $0.displayTitle }),
            .init("importance", title: "Importance", localizesValues: true, keyPath: \.importance, display: { $0.displayTitle }),
            .init("mastery", title: "Mastery", localizesValues: true, keyPath: \.masteryLevel, display: { $0.displayTitle })
        ]
    }
}
