import CryptoKit
import Foundation

public enum WordNoteBackupKind: String, Codable, CaseIterable, Sendable {
    case automatic
    case manual
    case beforeMigration
    case beforeRestore
}

public struct WordNoteSnapshotCounts: Codable, Equatable, Sendable {
    public var courses: Int
    public var inputRecords: Int
    public var candidates: Int
    public var terms: Int
    public var reviewEvents: Int

    public var total: Int { courses + inputRecords + candidates + terms + reviewEvents }
}

public struct WordNoteSnapshotDocument: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var sourceSchemaVersion: String
    public var appVersion: String
    public var snapshotID: UUID
    public var createdAt: Date
    public var kind: WordNoteBackupKind
    public var counts: WordNoteSnapshotCounts
    public var payloadChecksum: String
    public var payload: String
}

public struct DecodedWordNoteSnapshot: Sendable {
    public let document: WordNoteSnapshotDocument
    public let payload: WordNoteSnapshotPayload
}

public enum WordNoteSnapshotCodec {
    public static let maximumDocumentBytes = 64 * 1_024 * 1_024
    public static let currentFormatVersion = 1
    public static let currentSchemaVersion = "1.0.0"

    public static func encode(
        _ payload: WordNoteSnapshotPayload,
        kind: WordNoteBackupKind,
        snapshotID: UUID = UUID(),
        createdAt: Date = Date(),
        appVersion: String = "development"
    ) throws -> Data {
        try payload.validate()
        guard createdAt.timeIntervalSince1970.isFinite,
              abs(createdAt.timeIntervalSince1970) < 100_000_000_000,
              appVersion.count <= 128 else { throw WordNoteSnapshotError.invalidValue }
        let payloadData = try encoder().encode(payload)
        guard payloadData.count <= maximumDocumentBytes else { throw WordNoteSnapshotError.sizeLimit }
        let document = WordNoteSnapshotDocument(
            formatVersion: currentFormatVersion, sourceSchemaVersion: currentSchemaVersion,
            appVersion: appVersion, snapshotID: snapshotID, createdAt: createdAt, kind: kind,
            counts: payload.counts, payloadChecksum: checksum(payloadData),
            payload: String(decoding: payloadData, as: UTF8.self)
        )
        let data = try encoder().encode(document)
        guard data.count <= maximumDocumentBytes else { throw WordNoteSnapshotError.sizeLimit }
        return data
    }

    public static func decode(_ data: Data) throws -> DecodedWordNoteSnapshot {
        guard data.count <= maximumDocumentBytes else { throw WordNoteSnapshotError.sizeLimit }
        let document: WordNoteSnapshotDocument
        do {
            document = try JSONDecoder().decode(WordNoteSnapshotDocument.self, from: data)
        } catch {
            throw WordNoteSnapshotError.invalidDocument
        }
        guard document.formatVersion == currentFormatVersion else { throw WordNoteSnapshotError.unsupportedFormat }
        guard document.sourceSchemaVersion == currentSchemaVersion else { throw WordNoteSnapshotError.unsupportedSchema }
        guard document.appVersion.count <= 128,
              document.createdAt.timeIntervalSince1970.isFinite,
              abs(document.createdAt.timeIntervalSince1970) < 100_000_000_000 else {
            throw WordNoteSnapshotError.invalidValue
        }
        let payloadData = Data(document.payload.utf8)
        guard checksum(payloadData) == document.payloadChecksum else { throw WordNoteSnapshotError.checksumMismatch }
        let payload: WordNoteSnapshotPayload
        do {
            payload = try JSONDecoder().decode(WordNoteSnapshotPayload.self, from: payloadData)
        } catch {
            throw WordNoteSnapshotError.invalidDocument
        }
        try payload.validate()
        guard document.counts == payload.counts else { throw WordNoteSnapshotError.countMismatch }
        return DecodedWordNoteSnapshot(document: document, payload: payload)
    }

    public static func contentChecksum(_ payload: WordNoteSnapshotPayload) throws -> String {
        try payload.validate()
        return checksum(try encoder().encode(payload))
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public extension WordNoteSnapshotPayload {
    var counts: WordNoteSnapshotCounts {
        WordNoteSnapshotCounts(
            courses: courses.count, inputRecords: inputRecords.count,
            candidates: candidates.count, terms: terms.count, reviewEvents: reviewEvents.count
        )
    }
}
