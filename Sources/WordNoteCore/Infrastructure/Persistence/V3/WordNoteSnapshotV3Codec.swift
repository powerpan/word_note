import CryptoKit
import Foundation

public struct WordNoteSnapshotV3Counts: Codable, Equatable, Sendable {
    public var courses: Int
    public var inputRecords: Int
    public var candidates: Int
    public var terms: Int
    public var reviewEvents: Int
    public var occurrences: Int
    public var courseLinks: Int
    public var lookupEvents: Int
    public var cards: Int
    public var sessions: Int
    public var sessionItems: Int

    public var total: Int { courses + inputRecords + candidates + terms + reviewEvents + occurrences + courseLinks + lookupEvents + cards + sessions + sessionItems }
}

public struct WordNoteSnapshotV3Document: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var sourceSchemaVersion: String
    public var appVersion: String
    public var snapshotID: UUID
    public var createdAt: Date
    public var kind: WordNoteBackupKind
    public var counts: WordNoteSnapshotV3Counts
    public var payloadChecksum: String
    public var payload: String
}

public struct DecodedWordNoteSnapshotV3: Sendable {
    public let document: WordNoteSnapshotV3Document
    public let payload: WordNoteSnapshotV3Payload
}

public enum WordNoteSnapshotV3Codec {
    public static let maximumDocumentBytes = 64 * 1_024 * 1_024
    public static let currentFormatVersion = 5
    public static let currentSchemaVersion = "3.0.0"

    public static func encode(
        _ payload: WordNoteSnapshotV3Payload,
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
        let document = WordNoteSnapshotV3Document(
            formatVersion: currentFormatVersion, sourceSchemaVersion: currentSchemaVersion,
            appVersion: appVersion, snapshotID: snapshotID, createdAt: createdAt, kind: kind,
            counts: payload.counts, payloadChecksum: checksum(payloadData),
            payload: String(decoding: payloadData, as: UTF8.self)
        )
        let data = try encoder().encode(document)
        guard data.count <= maximumDocumentBytes else { throw WordNoteSnapshotError.sizeLimit }
        return data
    }

    public static func decode(_ data: Data) throws -> DecodedWordNoteSnapshotV3 {
        guard data.count <= maximumDocumentBytes else { throw WordNoteSnapshotError.sizeLimit }
        let document: WordNoteSnapshotV3Document
        do {
            document = try JSONDecoder().decode(WordNoteSnapshotV3Document.self, from: data)
        } catch {
            throw WordNoteSnapshotError.invalidDocument
        }
        guard (1...currentFormatVersion).contains(document.formatVersion) else { throw WordNoteSnapshotError.unsupportedFormat }
        guard document.sourceSchemaVersion == currentSchemaVersion else { throw WordNoteSnapshotError.unsupportedSchema }
        guard document.appVersion.count <= 128,
              document.createdAt.timeIntervalSince1970.isFinite,
              abs(document.createdAt.timeIntervalSince1970) < 100_000_000_000 else {
            throw WordNoteSnapshotError.invalidValue
        }
        let payloadData = Data(document.payload.utf8)
        guard checksum(payloadData) == document.payloadChecksum else { throw WordNoteSnapshotError.checksumMismatch }
        let payload: WordNoteSnapshotV3Payload
        do {
            payload = try JSONDecoder().decode(WordNoteSnapshotV3Payload.self, from: payloadData)
        } catch {
            throw WordNoteSnapshotError.invalidDocument
        }
        if document.formatVersion < payload.minimumRequiredFormatVersion {
            throw WordNoteSnapshotError.unsupportedFormat
        }
        try payload.validate()
        guard document.counts == payload.counts else { throw WordNoteSnapshotError.countMismatch }
        return DecodedWordNoteSnapshotV3(document: document, payload: payload)
    }

    public static func contentChecksum(_ payload: WordNoteSnapshotV3Payload) throws -> String {
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

public extension WordNoteSnapshotV3Payload {
    var counts: WordNoteSnapshotV3Counts {
        WordNoteSnapshotV3Counts(
            courses: content.content.courses.count, inputRecords: content.content.inputRecords.count,
            candidates: content.content.candidates.count, terms: content.content.terms.count, reviewEvents: content.content.reviewEvents.count,
            occurrences: content.occurrences.count, courseLinks: content.courseLinks.count, lookupEvents: content.lookupEvents.count,
            cards: cards.count, sessions: sessions.count, sessionItems: sessionItems.count
        )
    }
}
