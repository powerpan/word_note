import Foundation

public struct WordNoteV2OrganizationChanges: Equatable, Sendable {
    public var coursesToAdd: Set<UUID> = []
    public var coursesToRemove: Set<UUID> = []
    public var tagsToAdd: [String] = []
    public var tagsToRemove: [String] = []
    public init() {}
}

public enum WordNoteV2OrganizationError: LocalizedError, Equatable {
    case emptySelection, emptyChanges, conflictingChanges, stalePlan
    public var errorDescription: String? {
        switch self {
        case .emptySelection: "Select at least one vocabulary entry."
        case .emptyChanges: "Choose a course or tag change before previewing."
        case .conflictingChanges: "The same course or tag cannot be added and removed together."
        case .stalePlan: "Vocabulary or course data changed. Refresh the preview; nothing was saved."
        }
    }
}

public struct WordNoteV2OrganizationPlan: Sendable, Identifiable {
    public let id = UUID()
    public let changes: WordNoteV2OrganizationChanges
    public let entries: [Entry]
    public let courses: [WordNoteSnapshotPayload.Course]
    let courseRevisions: [WordNoteSnapshotV2Payload.CourseRevision]

    public struct Entry: Sendable, Identifiable {
        public let before: WordNoteSnapshotPayload.Term
        public let tagsAfter: [String]
        public let addedTags: [String]
        public let removedTags: [String]
        public let addedCourseIDs: [UUID]
        public let removedCourseIDs: [UUID]
        let state: WordNoteSnapshotV2Payload.TermState
        let links: [WordNoteSnapshotV2Payload.CourseLink]
        public var id: UUID { before.id }
        public var hasChanges: Bool { !addedTags.isEmpty || !removedTags.isEmpty || !addedCourseIDs.isEmpty || !removedCourseIDs.isEmpty }
    }

    public struct Counts: Equatable, Sendable {
        public let selectedTerms: Int
        public let changedTerms: Int
        public let coursesAdded: Int
        public let coursesRemoved: Int
        public let tagsAdded: Int
        public let tagsRemoved: Int
    }

    public var counts: Counts {
        .init(selectedTerms: entries.count, changedTerms: entries.filter(\.hasChanges).count,
              coursesAdded: entries.reduce(0) { $0 + $1.addedCourseIDs.count },
              coursesRemoved: entries.reduce(0) { $0 + $1.removedCourseIDs.count },
              tagsAdded: entries.reduce(0) { $0 + $1.addedTags.count },
              tagsRemoved: entries.reduce(0) { $0 + $1.removedTags.count })
    }
}
