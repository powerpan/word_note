import CryptoKit
import Foundation

public struct WordNoteRepairEvidenceSummary: Equatable, Sendable {
    public let id: UUID
    public let generation: WordNoteStoreGeneration
    public let createdAt: Date
    public let counts: WordNoteSnapshotV2Counts
    public let payloadChecksum: String
}

struct VerifiedWordNoteRepairEvidence: Sendable {
    let summary: WordNoteRepairEvidenceSummary
    let payload: WordNoteSnapshotV2Payload
}

/// Preserves invalid relationships for investigation. These files are never normal restore inputs.
public actor WordNoteRepairEvidenceVault {
    public enum Checkpoint: Sendable { case beforeWrite, afterWrite }
    public nonisolated let directoryURL: URL
    private let fault: (@Sendable (Checkpoint) throws -> Void)?
    private static let maximumBytes = WordNoteSnapshotV2Codec.maximumDocumentBytes

    private struct Document: Codable {
        var purpose = "wordnote-integrity-evidence"
        var evidenceFormatVersion = 1
        var schemaVersion = "2.0.0"
        let id: UUID
        let generation: WordNoteStoreGeneration
        let createdAt: Date
        let counts: WordNoteSnapshotV2Counts
        let payloadChecksum: String
        let payload: String

        var summary: WordNoteRepairEvidenceSummary {
            .init(id: id, generation: generation, createdAt: createdAt, counts: counts, payloadChecksum: payloadChecksum)
        }
    }

    public init(directoryURL: URL, fault: (@Sendable (Checkpoint) throws -> Void)? = nil) {
        self.directoryURL = directoryURL
        self.fault = fault
    }

    func create(
        _ source: WordNoteSnapshotV2Payload, generation: WordNoteStoreGeneration, at date: Date = Date()
    ) throws -> VerifiedWordNoteRepairEvidence {
        guard generation != .legacy, date.timeIntervalSince1970.isFinite,
              abs(date.timeIntervalSince1970) < 100_000_000_000 else { throw WordNoteSnapshotError.invalidValue }
        let payload = try Self.encoder().encode(source.canonicalized)
        guard payload.count <= Self.maximumBytes else { throw WordNoteSnapshotError.sizeLimit }
        let document = Document(
            id: UUID(), generation: generation, createdAt: date, counts: source.counts,
            payloadChecksum: Self.checksum(payload), payload: String(decoding: payload, as: UTF8.self)
        )
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

    func read(id: UUID) throws -> VerifiedWordNoteRepairEvidence {
        let data = try PrivateFileIO.read(fileURL(id), maximumBytes: Self.maximumBytes)
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw WordNoteSnapshotError.invalidDocument }
        guard document.purpose == "wordnote-integrity-evidence", document.id == id,
              document.generation != .legacy else { throw WordNoteSnapshotError.invalidDocument }
        guard document.evidenceFormatVersion == 1 else { throw WordNoteSnapshotError.unsupportedFormat }
        guard document.schemaVersion == "2.0.0" else { throw WordNoteSnapshotError.unsupportedSchema }
        guard document.createdAt.timeIntervalSince1970.isFinite,
              abs(document.createdAt.timeIntervalSince1970) < 100_000_000_000 else { throw WordNoteSnapshotError.invalidValue }
        let payloadData = Data(document.payload.utf8)
        guard Self.checksum(payloadData) == document.payloadChecksum else { throw WordNoteSnapshotError.checksumMismatch }
        let payload: WordNoteSnapshotV2Payload
        do { payload = try JSONDecoder().decode(WordNoteSnapshotV2Payload.self, from: payloadData) }
        catch { throw WordNoteSnapshotError.invalidDocument }
        guard payload.counts == document.counts else { throw WordNoteSnapshotError.countMismatch }
        return VerifiedWordNoteRepairEvidence(summary: document.summary, payload: payload)
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
