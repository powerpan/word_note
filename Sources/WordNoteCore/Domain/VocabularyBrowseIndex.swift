import Foundation

public enum VocabularySort: String, CaseIterable, Identifiable, Sendable {
    case updated, added, alphabetical, lastRequery, mostRequeried
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .updated: "Recently updated"
        case .added: "Recently added"
        case .alphabetical: "English A-Z"
        case .lastRequery: "Last re-query"
        case .mostRequeried: "Most re-queried"
        }
    }
}

public enum VocabularyActivity: String, CaseIterable, Identifiable, Sendable {
    case all, recentRequery, repeatedRequery
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: "All activity"
        case .recentRequery: "Re-queried in 7 days"
        case .repeatedRequery: "Re-queried 2+ times"
        }
    }
}

public struct VocabularyBrowseQuery: Equatable, Sendable {
    public var text = ""
    public var courseID: UUID?
    public var mastery: MasteryLevel?
    public var tag: String?
    public var activity: VocabularyActivity = .all
    public var sort: VocabularySort = .updated
    public init() {}

    public func hasSameScope(as other: Self) -> Bool {
        text == other.text && courseID == other.courseID && mastery == other.mastery && tag == other.tag && activity == other.activity
    }
}

public struct VocabularyBrowseItem: Sendable, Identifiable {
    public let term: WordNoteSnapshotPayload.Term
    public let courseIDs: Set<UUID>
    let search: VocabularySearchMatcher.Entry
    let tagKeys: Set<String>
    let requeryDates: [Date]
    public var id: UUID { term.id }
    public var chineseSummary: String { (term.chineseMeaning ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    public func requeryCount(at now: Date) -> Int {
        var lower = 0, upper = requeryDates.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if requeryDates[middle] <= now { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
    public func lastRequery(at now: Date) -> Date? {
        let count = requeryCount(at: now)
        return count == 0 ? nil : requeryDates[count - 1]
    }
}

/// Value-only search keys are built once per stored-data revision, not once per keystroke.
public struct VocabularyBrowseIndex: Sendable {
    public let items: [VocabularyBrowseItem]
    public let tags: [WordNoteTags.Option]

    public init(
        terms: [WordNoteSnapshotPayload.Term] = [], courseLinks: [WordNoteSnapshotV2Payload.CourseLink] = [],
        lookupEvents: [WordNoteSnapshotV2Payload.LookupEvent] = []
    ) {
        let links = Dictionary(grouping: courseLinks, by: \.termID)
        let events = Dictionary(grouping: lookupEvents.filter {
            $0.kindRaw == LookupEventKind.exactRepeat.rawValue && $0.occurredAt.timeIntervalSince1970.isFinite
        }, by: \.termID)
        items = terms.map { term in
            let captures = Dictionary(grouping: events[term.id, default: []], by: \.captureID)
            let dates = captures.values.compactMap { $0.map(\.occurredAt).min() }.sorted()
            return VocabularyBrowseItem(
                term: term, courseIDs: Set(links[term.id, default: []].map(\.courseID)),
                search: .init(term: term.term, chineseMeaning: term.chineseMeaning, englishDefinition: term.englishDefinition),
                tagKeys: Set(term.tags.map(WordNoteTags.key)), requeryDates: dates
            )
        }
        tags = WordNoteTags.options(terms.flatMap(\.tags))
    }

    public func matching(_ query: VocabularyBrowseQuery, at now: Date) -> [VocabularyBrowseItem] {
        let search = VocabularySearchMatcher.Query(query.text)
        let start = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let filtered = items.filter { item in
            guard item.search.matches(search), query.courseID.map({ item.courseIDs.contains($0) }) ?? true,
                  query.mastery.map({ item.term.masteryLevelRaw == $0.rawValue }) ?? true,
                  query.tag.map({ item.tagKeys.contains(WordNoteTags.key($0)) }) ?? true else { return false }
            switch query.activity {
            case .all: return true
            case .recentRequery: return item.lastRequery(at: now).map { $0 >= start } ?? false
            case .repeatedRequery: return item.requeryCount(at: now) >= 2
            }
        }
        return filtered.sorted { lhs, rhs in
            switch query.sort {
            case .updated:
                if lhs.term.updatedAt != rhs.term.updatedAt { return lhs.term.updatedAt > rhs.term.updatedAt }
            case .added:
                if lhs.term.createdAt != rhs.term.createdAt { return lhs.term.createdAt > rhs.term.createdAt }
            case .lastRequery:
                let left = lhs.lastRequery(at: now), right = rhs.lastRequery(at: now)
                if left != right { return optionalDateDescending(left, right) }
            case .mostRequeried:
                let left = lhs.requeryCount(at: now), right = rhs.requeryCount(at: now)
                if left != right { return left > right }
            case .alphabetical: break
            }
            let comparison = lhs.term.term.compare(rhs.term.term, options: [.caseInsensitive, .numeric], locale: Locale(identifier: "en_US_POSIX"))
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func optionalDateDescending(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (.some(let left), .some(let right)): left > right
        case (.some, .none): true
        default: false
        }
    }
}
