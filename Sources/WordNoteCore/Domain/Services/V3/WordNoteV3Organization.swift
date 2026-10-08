import Foundation

extension WordNoteV3ContentService {
    public func makeOrganizationPlan(
        termIDs: Set<UUID>, changes: WordNoteV2OrganizationChanges
    ) throws -> WordNoteV2OrganizationPlan {
        try WordNoteWriteGate.check(context)
        guard !context.hasChanges else { throw WordNoteV3ContentError.unsavedChanges }
        guard !termIDs.isEmpty else { throw WordNoteV2OrganizationError.emptySelection }
        let requestedCourseIDs = changes.coursesToAdd.union(changes.coursesToRemove)
        guard !requestedCourseIDs.isEmpty || !changes.tagsToAdd.isEmpty || !changes.tagsToRemove.isEmpty else {
            throw WordNoteV2OrganizationError.emptyChanges
        }
        let labels = try changes.tagsToAdd.map(WordNoteTags.newLabel)
        let removedKeys = Set(changes.tagsToRemove.map(WordNoteTags.key))
        guard !removedKeys.contains(""), changes.tagsToRemove.allSatisfy({ $0.count <= WordNoteSnapshotPayload.maximumTextCharacters }) else {
            throw WordNoteV3ContentError.invalidValue
        }
        guard changes.coursesToAdd.isDisjoint(with: changes.coursesToRemove),
              Set(labels.map(WordNoteTags.key)).isDisjoint(with: removedKeys) else {
            throw WordNoteV2OrganizationError.conflictingChanges
        }
        let selected = try fetch(Term.self).filter { termIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
        guard selected.count == termIDs.count else { throw WordNoteV3ContentError.missingEntity }
        let courses = try requestedCourseIDs.sorted { $0.uuidString < $1.uuidString }.map { try course($0) }
        let allLinks = Dictionary(grouping: try fetch(CourseLink.self), by: \.termID)
        let entries: [WordNoteV2OrganizationPlan.Entry] = try selected.map { term in
            let links = allLinks[term.id, default: []].map(WordNoteSnapshotV2Payload.CourseLink.init)
                .sorted { $0.id.uuidString < $1.id.uuidString }
            let courseIDs = Set(links.map(\.courseID))
            guard courseIDs.count == links.count else { throw WordNoteV3ContentError.invalidState }
            var tags = term.tags.filter { !removedKeys.contains(WordNoteTags.key($0)) }
            var keys = Set(tags.map(WordNoteTags.key))
            for label in labels where keys.insert(WordNoteTags.key(label)).inserted { tags.append(label) }
            guard tags.count <= 10_000 else { throw WordNoteSnapshotError.sizeLimit }
            let oldKeys = Set(term.tags.map(WordNoteTags.key))
            return .init(
                before: .init(term), tagsAfter: tags,
                addedTags: WordNoteTags.options(tags).filter { !oldKeys.contains($0.id) }.map(\.label),
                removedTags: WordNoteTags.options(term.tags).filter { !keys.contains($0.id) }.map(\.label),
                addedCourseIDs: changes.coursesToAdd.subtracting(courseIDs).sorted { $0.uuidString < $1.uuidString },
                removedCourseIDs: changes.coursesToRemove.intersection(courseIDs).sorted { $0.uuidString < $1.uuidString },
                state: .init(term), links: links
            )
        }
        return .init(changes: changes, entries: entries, courses: courses.map(WordNoteSnapshotPayload.Course.init),
                     courseRevisions: courses.map(WordNoteSnapshotV2Payload.CourseRevision.init))
    }

    public func commitOrganizationPlan(
        _ plan: WordNoteV2OrganizationPlan, at date: Date = Date()
    ) throws -> WordNoteV2OrganizationPlan.Counts {
        let changedIDs = Set(plan.entries.filter(\.hasChanges).map(\.id))
        return try undoableTransaction("Organize Vocabulary", scope: { .init(terms: changedIDs) }) {
            try validateDate(date)
            let terms = Dictionary(uniqueKeysWithValues: try fetch(Term.self).map { ($0.id, $0) })
            let links = Dictionary(grouping: try fetch(CourseLink.self), by: \.termID)
            let courses = Dictionary(uniqueKeysWithValues: try fetch(Course.self).map { ($0.id, $0) })
            let courseRevisions = Dictionary(uniqueKeysWithValues: plan.courseRevisions.map { ($0.id, $0.revision) })
            for expected in plan.courses {
                guard let course = courses[expected.id],
                      WordNoteSnapshotPayload.Course(course) == expected,
                      course.revision == courseRevisions[course.id] else {
                    throw WordNoteV2OrganizationError.stalePlan
                }
            }
            for entry in plan.entries {
                guard let term = terms[entry.id], WordNoteSnapshotPayload.Term(term) == entry.before,
                      WordNoteSnapshotV2Payload.TermState(term) == entry.state,
                      links[entry.id, default: []].map(WordNoteSnapshotV2Payload.CourseLink.init)
                        .sorted(by: { $0.id.uuidString < $1.id.uuidString }) == entry.links else {
                    throw WordNoteV2OrganizationError.stalePlan
                }
                if entry.hasChanges { _ = try increment(term.revision) }
            }
            for entry in plan.entries where entry.hasChanges {
                guard let value = terms[entry.id] else { throw WordNoteV2OrganizationError.stalePlan }
                for link in links[entry.id, default: []] where entry.removedCourseIDs.contains(link.courseID) {
                    context.delete(link)
                }
                // Every course and existing membership was checked above before any mutation.
                for courseID in entry.addedCourseIDs {
                    context.insert(CourseLink(termID: entry.id, courseID: courseID, createdAt: date))
                }
                if value.tags != entry.tagsAfter { value.tags = entry.tagsAfter }
                try touch(value, at: date)
            }
            return plan.counts
        }
    }
}
