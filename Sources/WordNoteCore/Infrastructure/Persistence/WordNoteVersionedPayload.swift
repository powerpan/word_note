import Foundation
import SwiftData

public enum WordNoteDataSchemaVersion: String, Codable, Sendable {
    case v1 = "1.0.0"
    case v2 = "2.0.0"
}

/// Inventory counts, not a replacement for either version's frozen on-disk document.
public struct WordNoteBackupCounts: Codable, Equatable, Sendable {
    public let courses: Int
    public let inputRecords: Int
    public let candidates: Int
    public let terms: Int
    public let reviewEvents: Int
    public let occurrences: Int
    public let courseLinks: Int
    public let lookupEvents: Int

    public var total: Int { courses + inputRecords + candidates + terms + reviewEvents + occurrences + courseLinks + lookupEvents }

    init(_ counts: WordNoteSnapshotCounts) {
        courses = counts.courses
        inputRecords = counts.inputRecords
        candidates = counts.candidates
        terms = counts.terms
        reviewEvents = counts.reviewEvents
        occurrences = 0
        courseLinks = 0
        lookupEvents = 0
    }

    init(_ counts: WordNoteSnapshotV2Counts) {
        courses = counts.courses
        inputRecords = counts.inputRecords
        candidates = counts.candidates
        terms = counts.terms
        reviewEvents = counts.reviewEvents
        occurrences = counts.occurrences
        courseLinks = counts.courseLinks
        lookupEvents = counts.lookupEvents
    }
}

public enum WordNoteVersionedPayload: Equatable, Sendable {
    case v1(WordNoteSnapshotPayload)
    case v2(WordNoteSnapshotV2Payload)

    public var schemaVersion: WordNoteDataSchemaVersion {
        switch self {
        case .v1: .v1
        case .v2: .v2
        }
    }

    public var counts: WordNoteBackupCounts {
        switch self {
        case .v1(let payload): WordNoteBackupCounts(payload.counts)
        case .v2(let payload): WordNoteBackupCounts(payload.counts)
        }
    }

    public var preferences: WordNoteSnapshotPayload.Preferences {
        switch self {
        case .v1(let payload): payload.preferences
        case .v2(let payload): payload.content.preferences
        }
    }

    public func validate() throws {
        switch self {
        case .v1(let payload): try payload.validate()
        case .v2(let payload): try payload.validate()
        }
    }

    var canonicalized: Self {
        switch self {
        case .v1(let payload): .v1(payload.canonicalized)
        case .v2(let payload): .v2(payload.canonicalized)
        }
    }

    var requiresAnalysisResume: Bool {
        switch self {
        case .v1(let payload): payload.inputRecords.contains { $0.statusRaw == "analyzing" }
        case .v2(let payload):
            payload.content.inputRecords.contains { $0.statusRaw == "analyzing" }
                || payload.recordStates.contains { ["queued", "running", "failed"].contains($0.queueStateRaw) }
        }
    }

    func populateEmptyStore(_ context: ModelContext) throws {
        switch self {
        case .v1(let payload): try payload.populateEmptyStore(context)
        case .v2(let payload): try payload.populateEmptyStore(context)
        }
    }

    public func contentChecksum() throws -> String {
        switch self {
        case .v1(let payload): try WordNoteSnapshotCodec.contentChecksum(payload)
        case .v2(let payload): try WordNoteSnapshotV2Codec.contentChecksum(payload)
        }
    }

    public func encode(
        kind: WordNoteBackupKind, snapshotID: UUID = UUID(), createdAt: Date = Date(), appVersion: String = "development"
    ) throws -> Data {
        switch self {
        case .v1(let payload):
            try WordNoteSnapshotCodec.encode(payload, kind: kind, snapshotID: snapshotID, createdAt: createdAt, appVersion: appVersion)
        case .v2(let payload):
            try WordNoteSnapshotV2Codec.encode(payload, kind: kind, snapshotID: snapshotID, createdAt: createdAt, appVersion: appVersion)
        }
    }

    /// Access must stay on the context's owning executor, including on a background reader.
    public static func capture(
        from context: ModelContext, preferences: WordNoteSnapshotPayload.Preferences = .init()
    ) throws -> Self {
        switch context.container.schema.version {
        case WordNoteSchemaV1.versionIdentifier: return .v1(try WordNoteSnapshotPayload.capture(from: context, preferences: preferences))
        case WordNoteSchemaV2.versionIdentifier: return .v2(try WordNoteSnapshotV2Payload.capture(from: context, preferences: preferences))
        default: throw WordNoteSnapshotError.unsupportedSchema
        }
    }
}

public extension VersionedWordNoteSnapshot {
    var payload: WordNoteVersionedPayload {
        switch self {
        case .v1(let snapshot): .v1(snapshot.payload)
        case .v2(let snapshot): .v2(snapshot.payload)
        }
    }

    var summary: WordNoteBackupSummary {
        switch self {
        case .v1(let snapshot): WordNoteBackupSummary(snapshot.document)
        case .v2(let snapshot): WordNoteBackupSummary(snapshot.document)
        }
    }
}
