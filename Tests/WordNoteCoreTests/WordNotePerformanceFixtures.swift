import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
enum WordNotePerformanceFixtures {
    static func v1(termCount: Int) throws -> WordNoteSnapshotPayload {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        defer { withExtendedLifetime(container) {} }
        try WordNoteTestFixture.populated.populate(container.mainContext)
        let seed = try WordNoteSnapshotPayload.capture(from: container.mainContext)
        var result = WordNoteSnapshotPayload(courses: seed.courses, inputRecords: [], candidates: [], terms: [], reviewEvents: [], preferences: .init())
        for index in 0..<termCount {
            let termID = id(index, family: 1)
            let recordID = id(index, family: 2)
            let courseID = seed.courses[index % seed.courses.count].id
            let termText = "synthetic vocabulary term \(index)"
            var record = seed.inputRecords[index % seed.inputRecords.count]
            record.id = recordID
            record.rawText = "An example sentence containing \(termText) for a local performance fixture."
            record.normalizedText = TextNormalizer.normalized(record.rawText)
            record.statusRaw = InputRecordStatus.completed.rawValue
            record.courseID = courseID
            var candidate = seed.candidates[index % seed.candidates.count]
            candidate.id = id(index, family: 3)
            candidate.inputRecordID = recordID
            candidate.term = termText
            candidate.normalizedTerm = TextNormalizer.normalized(termText)
            candidate.statusRaw = CandidateStatus.saved.rawValue
            var term = seed.terms[index % seed.terms.count]
            term.id = termID
            term.term = termText
            term.normalizedTerm = candidate.normalizedTerm
            term.sourceRecordID = recordID
            term.courseID = courseID
            var event = seed.reviewEvents[0]
            event.id = id(index, family: 4)
            event.termID = termID
            result.inputRecords.append(record)
            result.candidates.append(candidate)
            result.terms.append(term)
            result.reviewEvents.append(event)
        }
        try result.validate()
        return result.canonicalized
    }

    private static func id(_ index: Int, family: Int) -> UUID {
        UUID(uuidString: String(format: "%08x-0000-0000-0000-%012x", family, index))!
    }
}
