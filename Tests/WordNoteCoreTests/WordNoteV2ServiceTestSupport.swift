import Foundation
import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
enum WordNoteV2ServiceTestSupport {
    static let now = WordNoteTestFixture.referenceDate.addingTimeInterval(1_000)

    enum Failure: Error, Equatable {
        case save
        case expectedInputRecord
    }

    static func container(populated: Bool = true) throws -> ModelContainer {
        let schema = Schema(versionedSchema: WordNoteSchemaV2.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        container.mainContext.autosaveEnabled = false
        if populated {
            let oldSchema = Schema(versionedSchema: WordNoteSchemaV1.self)
            let old = try ModelContainer(for: oldSchema, configurations: [ModelConfiguration(schema: oldSchema, isStoredInMemoryOnly: true)])
            try WordNoteTestFixture.populated.populate(old.mainContext)
            let migrated = try WordNoteV1ToV2Migration.convert(WordNoteSnapshotPayload.capture(from: old.mainContext))
            try migrated.payload.populateEmptyStore(container.mainContext)
        }
        return container
    }

    static func snapshot(_ container: ModelContainer) throws -> WordNoteSnapshotV2Payload {
        try WordNoteSnapshotV2Payload.capture(from: container.mainContext)
    }

    static func term(_ name: String, in container: ModelContainer) throws -> WordNoteSchemaV2.TermModel {
        try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV2.TermModel>()).first { $0.term == name })
    }

    static func candidate(_ name: String, in container: ModelContainer) throws -> WordNoteSchemaV2.CandidateTermModel {
        try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV2.CandidateTermModel>()).first { $0.term == name })
    }

    static func record(_ id: UUID, in container: ModelContainer) throws -> WordNoteSchemaV2.InputRecordModel {
        try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV2.InputRecordModel>()).first { $0.id == id })
    }

    static func inputID(_ result: WordNoteCaptureResult) throws -> UUID {
        guard case .inputRecord(let id, _) = result.destination else { throw Failure.expectedInputRecord }
        return id
    }
}
