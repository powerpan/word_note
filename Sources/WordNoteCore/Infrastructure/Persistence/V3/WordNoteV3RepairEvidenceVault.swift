import CryptoKit
import Foundation

public struct WordNoteV3RepairEvidenceSummary: Equatable, Sendable {
    public let id: UUID
    public let generation: WordNoteStoreGeneration
    public let createdAt: Date
    public let counts: WordNoteSnapshotV3Counts
    public let payloadChecksum: String
}

struct VerifiedWordNoteV3RepairEvidence: Sendable {
    let summary: WordNoteV3RepairEvidenceSummary
    let payload: WordNoteSnapshotV3Payload
}

/// Invalid relationships are retained verbatim. Evidence is not an ordinary backup or restore input.
public actor WordNoteV3RepairEvidenceVault {
    public enum Checkpoint: Sendable { case beforeWrite, afterWrite }
    public nonisolated let directoryURL: URL
    private let fault: (@Sendable (Checkpoint) throws -> Void)?
    private static let maximumBytes = WordNoteSnapshotV3Codec.maximumDocumentBytes

    private struct Document: Codable {
        var purpose = "wordnote-integrity-evidence"
        var evidenceFormatVersion = 2
        var schemaVersion = "3.0.0"
        let id: UUID
        let generation: WordNoteStoreGeneration
        let createdAt: Date
        let counts: WordNoteSnapshotV3Counts
        let payloadChecksum: String
        let payload: String

        var summary: WordNoteV3RepairEvidenceSummary {
            .init(id: id, generation: generation, createdAt: createdAt, counts: counts, payloadChecksum: payloadChecksum)
        }
    }

    public init(directoryURL: URL, fault: (@Sendable (Checkpoint) throws -> Void)? = nil) {
        self.directoryURL = directoryURL
        self.fault = fault
    }

    func create(_ source: WordNoteSnapshotV3Payload, generation: WordNoteStoreGeneration,
                at date: Date = Date()) throws -> VerifiedWordNoteV3RepairEvidence {
        guard generation != .legacy, date.timeIntervalSince1970.isFinite,
              abs(date.timeIntervalSince1970) < 100_000_000_000 else { throw WordNoteSnapshotError.invalidValue }
        let payload = try Self.encoder().encode(source.canonicalized)
        guard payload.count <= Self.maximumBytes else { throw WordNoteSnapshotError.sizeLimit }
        let document = Document(id: UUID(), generation: generation, createdAt: date, counts: source.counts,
            payloadChecksum: Self.checksum(payload), payload: String(decoding: payload, as: UTF8.self))
        let data = try Self.encoder().encode(document)
        guard data.count <= Self.maximumBytes else { throw WordNoteSnapshotError.sizeLimit }
        try PrivateFileIO.prepareDirectory(directoryURL)
        try fault?(.beforeWrite)
        try PrivateFileIO.write(data, to: fileURL(document.id), replaceExisting: false)
        try fault?(.afterWrite)
        let verified = try read(id: document.id)
        guard verified.summary == document.summary, verified.payload == source.canonicalized else {
            throw WordNoteStartupMigrationError.protectionMismatch
        }
        return verified
    }

    func read(id: UUID) throws -> VerifiedWordNoteV3RepairEvidence {
        let data = try PrivateFileIO.read(fileURL(id), maximumBytes: Self.maximumBytes)
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw WordNoteSnapshotError.invalidDocument }
        guard document.purpose == "wordnote-integrity-evidence", document.id == id,
              document.generation != .legacy else { throw WordNoteSnapshotError.invalidDocument }
        guard (1...2).contains(document.evidenceFormatVersion) else { throw WordNoteSnapshotError.unsupportedFormat }
        guard document.schemaVersion == "3.0.0" else { throw WordNoteSnapshotError.unsupportedSchema }
        guard document.createdAt.timeIntervalSince1970.isFinite,
              abs(document.createdAt.timeIntervalSince1970) < 100_000_000_000 else { throw WordNoteSnapshotError.invalidValue }
        let payloadData = Data(document.payload.utf8)
        guard Self.checksum(payloadData) == document.payloadChecksum else { throw WordNoteSnapshotError.checksumMismatch }
        let payload: WordNoteSnapshotV3Payload
        do { payload = try JSONDecoder().decode(WordNoteSnapshotV3Payload.self, from: payloadData) }
        catch { throw WordNoteSnapshotError.invalidDocument }
        if document.evidenceFormatVersion == 1, payload.sessions.contains(where: { $0.introductions != nil }) {
            throw WordNoteSnapshotError.unsupportedFormat
        }
        guard payload.counts == document.counts else { throw WordNoteSnapshotError.countMismatch }
        return .init(summary: document.summary, payload: payload)
    }

    func fileURL(_ id: UUID) -> URL {
        directoryURL.appending(path: "\(id.uuidString.lowercased()).wordnote-repair-evidence.json")
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
