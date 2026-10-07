import Foundation

extension WordNoteV2ContentService {
    public func deleteInputRecord(_ id: UUID, expectedRevision: Int, at date: Date = Date()) throws {
        try transaction {
            try validateDate(date)
            let record = try record(id)
            try requireRevision(record.revision, expectedRevision)
            let occurrences = try fetch(Occurrence.self).filter { $0.sourceRecordID == id }
            let affectedTermIDs = Set(occurrences.map(\.termID))
            let terms = try fetch(Term.self).filter { $0.sourceRecordID == id || affectedTermIDs.contains($0.id) }
            for term in terms {
                if term.sourceRecordID == id { term.sourceRecordID = nil }
                try touch(term, at: date)
            }
            occurrences.forEach { $0.sourceRecordID = nil }
            try fetch(Candidate.self).filter { $0.inputRecordID == id }.forEach(context.delete)
            context.delete(record)
        }
    }

    public func deleteOccurrence(_ id: UUID, expectedTermRevision: Int, at date: Date = Date()) throws {
        try transaction {
            try validateDate(date)
            guard let occurrence = try fetch(Occurrence.self).first(where: { $0.id == id }) else {
                throw WordNoteV2ContentError.missingEntity
            }
            let term = try term(occurrence.termID)
            try requireRevision(term.revision, expectedTermRevision)
            try fetch(LookupEvent.self).filter { $0.occurrenceID == id }.forEach { $0.occurrenceID = nil }
            context.delete(occurrence)
            try touch(term, at: date)
        }
    }

    public func deleteTerm(_ id: UUID, expectedRevision: Int, at date: Date = Date()) throws {
        try transaction {
            try validateDate(date)
            let term = try term(id)
            try requireRevision(term.revision, expectedRevision)
            for candidate in try fetch(Candidate.self).filter({ $0.savedTermID == id }) {
                candidate.savedTermID = nil
                candidate.savedLinkStateRaw = "targetDeleted"
                candidate.revision = try increment(candidate.revision)
                candidate.updatedAt = date
            }
            try fetch(ReviewEvent.self).filter { $0.termID == id }.forEach(context.delete)
            try fetch(Occurrence.self).filter { $0.termID == id }.forEach(context.delete)
            try fetch(CourseLink.self).filter { $0.termID == id }.forEach(context.delete)
            try fetch(LookupEvent.self).filter { $0.termID == id }.forEach(context.delete)
            context.delete(term)
        }
    }

    public func deleteCourse(_ id: UUID, expectedRevision: Int, at date: Date = Date()) throws {
        try transaction {
            try validateDate(date)
            let course = try course(id)
            try requireRevision(course.revision, expectedRevision)
            let usage = try courseUsage(id)
            guard !usage.isInUse else { throw WordNoteV2ContentError.courseInUse(usage) }
            // The legacy snapshot is not membership authority, but must not become a dangling reference.
            for term in try fetch(Term.self).filter({ $0.courseID == id }) {
                term.courseID = nil
                try touch(term, at: date)
            }
            context.delete(course)
        }
    }
}
