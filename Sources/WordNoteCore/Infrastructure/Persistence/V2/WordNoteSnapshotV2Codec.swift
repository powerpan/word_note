import CryptoKit
import Foundation

public struct WordNoteSnapshotV2Counts: Codable, Equatable, Sendable {
    public var courses: Int
    public var inputRecords: Int
    public var candidates: Int
    public var terms: Int
    public var reviewEvents: Int
    public var occurrences: Int
    public var courseLinks: Int
    public var lookupEvents: Int

    public var total: Int { courses + inputRecords + candidates + terms + reviewEvents + occurrences + courseLinks + lookupEvents }
}

public struct WordNoteSnapshotV2Document: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var sourceSchemaVersion: String
    public var appVersion: String
    public var snapshotID: UUID
    public var createdAt: Date
    public var kind: WordNoteBackupKind
    public var counts: WordNoteSnapshotV2Counts
    public var payloadChecksum: String
    public var payload: String
}

public struct DecodedWordNoteSnapshotV2: Sendable {
    public let document: WordNoteSnapshotV2Document
    public let payload: WordNoteSnapshotV2Payload
}

public enum WordNoteSnapshotV2Codec {
    public static let maximumDocumentBytes = 64 * 1_024 * 1_024
    public static let currentFormatVersion = 1
    public static let currentSchemaVersion = "2.0.0"

    public static func encode(
        _ payload: WordNoteSnapshotV2Payload,
        kind: WordNoteBackupKind,
        snapshotID: UUID = UUID(),
        createdAt: Date = Date(),
        appVersion: String = "development"
    ) throws -> Data {
        try payload.validate()
        guard createdAt.timeIntervalSince1970.isFinite,
              abs(createdAt.timeIntervalSince1970) < 100_000_000_000,
              appVersion.count <= 128 else { throw WordNoteSnapshotError.invalidValue }
        let payloadData = try encoder().encode(payload.canonicalized)
        guard payloadData.count <= maximumDocumentBytes else { throw WordNoteSnapshotError.sizeLimit }
        let document = WordNoteSnapshotV2Document(
            formatVersion: currentFormatVersion, sourceSchemaVersion: currentSchemaVersion,
            appVersion: appVersion, snapshotID: snapshotID, createdAt: createdAt, kind: kind,
            counts: payload.counts, payloadChecksum: checksum(payloadData),
            payload: String(decoding: payloadData, as: UTF8.self)
        )
        let data = try encoder().encode(document)
        guard data.count <= maximumDocumentBytes else { throw WordNoteSnapshotError.sizeLimit }
        return data
    }

    public static func decode(_ data: Data) throws -> DecodedWordNoteSnapshotV2 {
        guard data.count <= maximumDocumentBytes else { throw WordNoteSnapshotError.sizeLimit }
        let document: WordNoteSnapshotV2Document
        do {
            document = try JSONDecoder().decode(WordNoteSnapshotV2Document.self, from: data)
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
        let payload: WordNoteSnapshotV2Payload
        do {
            payload = try JSONDecoder().decode(WordNoteSnapshotV2Payload.self, from: payloadData)
        } catch {
            throw WordNoteSnapshotError.invalidDocument
        }
        try payload.validate()
        guard document.counts == payload.counts else { throw WordNoteSnapshotError.countMismatch }
        return DecodedWordNoteSnapshotV2(document: document, payload: payload)
    }

    public static func contentChecksum(_ payload: WordNoteSnapshotV2Payload) throws -> String {
        try payload.validate()
        return checksum(try encoder().encode(payload.canonicalized))
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

public extension WordNoteSnapshotV2Payload {
    var counts: WordNoteSnapshotV2Counts {
        WordNoteSnapshotV2Counts(
            courses: content.courses.count, inputRecords: content.inputRecords.count,
            candidates: content.candidates.count, terms: content.terms.count, reviewEvents: content.reviewEvents.count,
            occurrences: occurrences.count, courseLinks: courseLinks.count, lookupEvents: lookupEvents.count
        )
    }
}
