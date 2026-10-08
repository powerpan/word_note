import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
enum WordNoteV3ServiceTestSupport {
    static let now = WordNoteV2ServiceTestSupport.now
    typealias Failure = WordNoteV2ServiceTestSupport.Failure

    static func container(populated: Bool = true) throws -> ModelContainer {
        let container = try V3TestSupport.container()
        if populated {
            let old = try WordNoteV2ServiceTestSupport.container()
            let payload = try WordNoteV2ToV3Migration.convert(WordNoteV2ServiceTestSupport.snapshot(old), at: now)
            try payload.populateEmptyStore(container.mainContext)
        }
        return container
    }

    static func fullSnapshot(_ container: ModelContainer) throws -> WordNoteSnapshotV3Payload {
        try .capture(from: container.mainContext)
    }

    // Reuse content-contract assertions while still validating every V3 relationship.
    static func contentSnapshot(_ container: ModelContainer) throws -> WordNoteSnapshotV2Payload {
        try fullSnapshot(container).content
    }

    static func term(_ name: String, in container: ModelContainer) throws -> WordNoteSchemaV3.TermModel {
        try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()).first { $0.term == name })
    }

    static func candidate(_ name: String, in container: ModelContainer) throws -> WordNoteSchemaV3.CandidateTermModel {
        try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.CandidateTermModel>()).first { $0.term == name })
    }

    static func record(_ id: UUID, in container: ModelContainer) throws -> WordNoteSchemaV3.InputRecordModel {
        try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.InputRecordModel>()).first { $0.id == id })
    }

    static func inputID(_ result: WordNoteCaptureResult) throws -> UUID {
        try WordNoteV2ServiceTestSupport.inputID(result)
    }

    static func selections(_ candidates: [WordNoteSchemaV3.CandidateTermModel], in container: ModelContainer) throws -> [WordNoteV2CandidateSelection] {
        try candidates.map { .init(id: $0.id, revision: $0.revision, recordID: $0.inputRecordID,
                                   recordRevision: try record($0.inputRecordID, in: container).revision) }
    }

    static func plan(_ names: [String], container: ModelContainer, service: WordNoteV3ContentService) throws -> WordNoteV2ConfirmationPlan {
        try service.makeConfirmationPlan(selections(names.map { try candidate($0, in: container) }, in: container))
    }
}
